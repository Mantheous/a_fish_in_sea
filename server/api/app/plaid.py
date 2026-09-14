"""Plaid API client factory + shared helpers (ported from the retired Flask server).

Auth model: each sync user owns at most one Plaid connection in the
``oauth_connections`` table (``provider='plaid'``), Fernet-encrypted when
``TOKEN_FERNET_KEY`` is set. The Flask server keyed tokens by an opaque
``X-Plaid-User-Id`` device header in ``.plaid_users.json``; every route
here instead requires the sync JWT, so bank tokens are unreachable
without the user's account credentials.

``plaid-python`` is a blocking (urllib3-based) SDK, so every network
call is dispatched with ``asyncio.to_thread`` to keep the event loop
responsive.
"""

from __future__ import annotations

import asyncio
import json
import os

import plaid
from fastapi.responses import JSONResponse
from plaid.api import plaid_api
from plaid.model.country_code import CountryCode
from plaid.model.products import Products


class PlaidConfigError(Exception):
    """Server is missing PLAID_CLIENT_ID / PLAID_SECRET."""


def empty_to_none(field: str) -> str | None:
    value = os.getenv(field)
    if value is None or len(value) == 0:
        return None
    return value


def plaid_products() -> list[Products]:
    return [Products(p) for p in os.getenv("PLAID_PRODUCTS", "transactions").split(",")]


def plaid_country_codes() -> list[CountryCode]:
    return [
        CountryCode(c) for c in os.getenv("PLAID_COUNTRY_CODES", "US").split(",")
    ]


def plaid_redirect_uri() -> str | None:
    return empty_to_none("PLAID_REDIRECT_URI")


def is_sandbox() -> bool:
    return os.getenv("PLAID_ENV", "sandbox") == "sandbox"


def get_client() -> plaid_api.PlaidApi:
    """Build a Plaid client from env. Raises PlaidConfigError without keys."""
    client_id = os.getenv("PLAID_CLIENT_ID")
    secret = os.getenv("PLAID_SECRET")
    if not client_id or not secret:
        raise PlaidConfigError(
            "Server is missing PLAID_CLIENT_ID / PLAID_SECRET"
        )
    env = os.getenv("PLAID_ENV", "sandbox")
    host = plaid.Environment.Sandbox
    if env == "production":
        host = plaid.Environment.Production
    configuration = plaid.Configuration(
        host=host,
        api_key={
            "clientId": client_id,
            "secret": secret,
            "plaidVersion": "2020-09-14",
        },
    )
    return plaid_api.PlaidApi(plaid.ApiClient(configuration))


def to_dict(obj) -> dict:
    """Plain-dict view of a Plaid model object (or a dict already)."""
    if isinstance(obj, dict):
        return obj
    if hasattr(obj, "to_dict"):
        return obj.to_dict()
    return dict(obj)


def pretty_print_response(response) -> None:
    print(json.dumps(response, indent=2, sort_keys=True, default=str))


# Full Plaid bodies contain account numbers and balances: never print
# them in normal operation. Opt back in for local debugging with
# LOG_SENSITIVE_RESPONSES=1.
_LOG_SENSITIVE = os.getenv("LOG_SENSITIVE_RESPONSES", "") == "1"


def log_response(response) -> None:
    if _LOG_SENSITIVE:
        pretty_print_response(response)
    else:
        kind = type(response).__name__
        try:
            size = len(response)
        except TypeError:
            size = "?"
        print(f"[response suppressed: {kind} len={size}]")


def format_plaid_error(e: "plaid.ApiException") -> dict:
    try:
        body = json.loads(e.body)
    except (json.JSONDecodeError, TypeError):
        body = {"error_message": str(getattr(e, "body", e))[:200]}
    if not isinstance(body, dict):
        body = {"error_message": str(body)[:200]}
    return {"error": {**body, "status_code": e.status}}


def plaid_error_response(e: "plaid.ApiException") -> JSONResponse:
    payload = format_plaid_error(e)
    pretty_print_response(payload)
    return JSONResponse(status_code=e.status or 500, content=payload)


async def poll_with_retries(request_callback, ms: int = 1000, retries: int = 20):
    """Poll a webhook-triggered Plaid endpoint until it is ready.

    ``request_callback`` is a sync callable (run in a worker thread).
    Retries ``PRODUCT_NOT_READY`` and 5xx; any other Plaid error raises
    immediately.
    """
    left = retries
    while True:
        try:
            return await asyncio.to_thread(request_callback)
        except plaid.ApiException as e:
            try:
                response = json.loads(e.body)
                error_code = response.get("error_code", "")
            except (json.JSONDecodeError, TypeError):
                error_code = ""
            retryable = error_code == "PRODUCT_NOT_READY" or e.status >= 500
            if not retryable or left <= 1:
                if retryable:
                    raise Exception("Ran out of retries while polling") from e
                raise
            left -= 1
            await asyncio.sleep(ms / 1000)
