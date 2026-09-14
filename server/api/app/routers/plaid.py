"""Plaid bank proxy (ported from the retired Flask server).

Same URL contracts as Flask (``/api/*``), so the Flutter client needs
no changes — but bank tokens are now per sync-user (DB + Fernet) instead
of opaque device-header buckets in ``.plaid_users.json``. Every route
except ``/link_exit_error`` (client telemetry) requires the sync JWT.

Deliberately NOT ported from the quickstart (unused by the app, and
the money-movement ones must never run outside a demo):
``create_link_token_for_payment``, ``create_user_token``, ``assets``,
``holdings``, ``investments_transactions``, ``transfer_authorize``,
``transfer_create``, ``statements``, ``signal_evaluate``, ``payment``,
``cra/*``. The Flask originals for transfers/payments used process-global
ids and hardcoded amounts — unsafe on a multi-user server.
"""

from __future__ import annotations

import asyncio
import json
import urllib.parse
from datetime import date, timedelta

import plaid
from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.auth_get_request import AuthGetRequest
from plaid.model.identity_get_request import IdentityGetRequest
from plaid.model.institutions_get_by_id_request import InstitutionsGetByIdRequest
from plaid.model.item_get_request import ItemGetRequest
from plaid.model.item_public_token_exchange_request import (
    ItemPublicTokenExchangeRequest,
)
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_statements import (
    LinkTokenCreateRequestStatements,
)
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.products import Products
from plaid.model.sandbox_public_token_create_request import (
    SandboxPublicTokenCreateRequest,
)
from plaid.model.transactions_sync_request import TransactionsSyncRequest
from sqlalchemy.ext.asyncio import AsyncSession

from .. import plaid as p
from ..db import get_session
from ..deps import get_current_user
from ..models import User
from ..oauth_store import (
    clear_connection,
    decrypt_secret,
    get_connection,
    save_connection,
)

router = APIRouter(tags=["plaid"])

_PROVIDER = "plaid"


def _missing_key_response(e: p.PlaidConfigError) -> JSONResponse:
    return JSONResponse(status_code=500, content={"error": {"message": str(e)}})


async def _access_token(
    session: AsyncSession, user: User
) -> tuple[str | None, JSONResponse | None]:
    row = await get_connection(session, user.id, _PROVIDER)
    token = decrypt_secret(row.access_token) if row else ""
    if not token:
        return None, JSONResponse(
            status_code=401,
            content={"error": {"message": "No bank account connected"}},
        )
    return token, None


@router.post("/info")
async def info(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    import os

    row = await get_connection(session, user.id, _PROVIDER)
    # Never disclose the Plaid access token: the sync JWT alone must not
    # be enough to exfiltrate bank credentials.
    return {
        "connected": bool(row and decrypt_secret(row.access_token)),
        "item_id": row.item_id if row else None,
        "products": os.getenv("PLAID_PRODUCTS", "transactions").split(","),
    }


@router.post("/sandbox/auto_connect")
async def sandbox_auto_connect(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    if not p.is_sandbox():
        return JSONResponse(
            status_code=400,
            content={"error": "Auto-connect is only available in sandbox mode"},
        )
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    try:
        # First Platypus Bank: no Link UI needed for desktop dev.
        pt_response = await asyncio.to_thread(
            client.sandbox_public_token_create,
            SandboxPublicTokenCreateRequest(
                institution_id="ins_109508",
                initial_products=[Products("transactions")],
            ),
        )
        exchange_response = await asyncio.to_thread(
            client.item_public_token_exchange,
            ItemPublicTokenExchangeRequest(
                public_token=pt_response["public_token"]
            ),
        )
        await save_connection(
            session,
            user.id,
            _PROVIDER,
            access_token=exchange_response["access_token"],
            item_id=exchange_response["item_id"],
            merge_refresh=False,
        )
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    return {
        "status": "connected",
        "item_id": exchange_response["item_id"],
    }


@router.post("/disconnect")
async def disconnect(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    await clear_connection(session, user.id, _PROVIDER)
    return {"status": "disconnected"}


@router.post("/create_link_token")
async def create_link_token(
    user: User = Depends(get_current_user),
):
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    products = p.plaid_products()
    plaid_request = LinkTokenCreateRequest(
        products=products,
        client_name="Plaid Quickstart",
        country_codes=p.plaid_country_codes(),
        language="en",
        android_package_name="com.example.a_fish_in_sea",
        user=LinkTokenCreateRequestUser(
            # Stable per sync-user id (Flask used the device header).
            client_user_id=str(user.id)
        ),
    )
    redirect_uri = p.plaid_redirect_uri()
    if redirect_uri is not None:
        plaid_request["redirect_uri"] = redirect_uri
    if Products("statements") in products:
        plaid_request["statements"] = LinkTokenCreateRequestStatements(
            end_date=date.today(),
            start_date=date.today() - timedelta(days=30),
        )
    try:
        response = await asyncio.to_thread(client.link_token_create, plaid_request)
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    return p.to_dict(response)


@router.post("/set_access_token")
async def set_access_token(
    request: Request,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    public_token = await _read_public_token(request)
    if not public_token:
        return JSONResponse(
            status_code=400,
            content={"error": {"message": "Missing public_token"}},
        )
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    try:
        exchange_response = await asyncio.to_thread(
            client.item_public_token_exchange,
            ItemPublicTokenExchangeRequest(public_token=public_token),
        )
        await save_connection(
            session,
            user.id,
            _PROVIDER,
            access_token=exchange_response["access_token"],
            item_id=exchange_response["item_id"],
            merge_refresh=False,
        )
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    # The access token stays server-side and must never be sent back.
    return {"item_id": exchange_response["item_id"]}


async def _read_public_token(request: Request) -> str | None:
    """Accept the Flutter client's form-encoded body as well as JSON."""
    ctype = request.headers.get("content-type", "")
    raw = await request.body()
    if "application/json" in ctype:
        try:
            data = json.loads(raw or b"null")
        except (json.JSONDecodeError, ValueError):
            return None
        if isinstance(data, dict):
            value = data.get("public_token")
            return value if isinstance(value, str) and value else None
        return None
    try:
        form = urllib.parse.parse_qs(raw.decode("utf-8", errors="replace"))
    except ValueError:
        return None
    values = form.get("public_token") or []
    return values[0] if values and values[0] else None


@router.get("/auth")
async def get_auth(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    token, err = await _access_token(session, user)
    if err is not None:
        return err
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    try:
        response = await asyncio.to_thread(
            client.auth_get, AuthGetRequest(access_token=token)
        )
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    p.log_response(p.to_dict(response))
    return p.to_dict(response)


@router.get("/transactions")
async def get_transactions(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    token, err = await _access_token(session, user)
    if err is not None:
        return err
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    try:
        # Full historical sync: cursor pages until has_more is false.
        cursor = ""
        added: list = []
        has_more = True
        while has_more:
            response = p.to_dict(
                await asyncio.to_thread(
                    client.transactions_sync,
                    TransactionsSyncRequest(
                        access_token=token, cursor=cursor
                    ),
                )
            )
            cursor = response["next_cursor"]
            # No data yet (webhook-less quickstart flow): wait and poll.
            if cursor == "":
                await asyncio.sleep(2)
                continue
            added.extend(response["added"])
            has_more = response["has_more"]
            p.log_response(response)
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    latest = sorted(added, key=lambda t: t["date"])
    return {"latest_transactions": latest}


@router.get("/identity")
async def get_identity(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    token, err = await _access_token(session, user)
    if err is not None:
        return err
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    try:
        response = await asyncio.to_thread(
            client.identity_get, IdentityGetRequest(access_token=token)
        )
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    p.log_response(p.to_dict(response))
    return {"error": None, "identity": p.to_dict(response)["accounts"]}


@router.get("/balance")
async def get_balance(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    token, err = await _access_token(session, user)
    if err is not None:
        return err
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    try:
        response = await asyncio.to_thread(
            client.accounts_balance_get,
            AccountsBalanceGetRequest(access_token=token),
        )
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    p.log_response(p.to_dict(response))
    return p.to_dict(response)


@router.get("/accounts")
async def get_accounts(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    token, err = await _access_token(session, user)
    if err is not None:
        return err
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    try:
        response = await asyncio.to_thread(
            client.accounts_get, AccountsGetRequest(access_token=token)
        )
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    p.log_response(p.to_dict(response))
    return p.to_dict(response)


@router.get("/item")
async def get_item(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    token, err = await _access_token(session, user)
    if err is not None:
        return err
    try:
        client = p.get_client()
    except p.PlaidConfigError as e:
        return _missing_key_response(e)
    try:
        response = await asyncio.to_thread(
            client.item_get, ItemGetRequest(access_token=token)
        )
        institution_response = await asyncio.to_thread(
            client.institutions_get_by_id,
            InstitutionsGetByIdRequest(
                institution_id=response["item"]["institution_id"],
                country_codes=p.plaid_country_codes(),
            ),
        )
    except plaid.ApiException as e:
        return p.plaid_error_response(e)
    p.log_response(p.to_dict(response))
    p.log_response(p.to_dict(institution_response))
    return {
        "error": None,
        "item": p.to_dict(response)["item"],
        "institution": p.to_dict(institution_response)["institution"],
    }


@router.post("/link_exit_error")
async def link_exit_error(request: Request):
    try:
        data = await request.json()
    except (json.JSONDecodeError, ValueError):
        return JSONResponse(
            status_code=400, content={"error": "Invalid JSON"}
        )
    print("[Link Exit Error (frontend)]")
    p.pretty_print_response(data)
    return {"status": "logged"}
