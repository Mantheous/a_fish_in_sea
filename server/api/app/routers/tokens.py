"""Scoped long-lived tokens for MCP agents and secondary devices."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import get_current_user
from ..models import COLLECTIONS, ApiToken, User
from ..schemas import ApiTokenCreateIn, ApiTokenCreated, ApiTokenOut
from ..security import hash_api_token, new_api_token

router = APIRouter(prefix="/tokens", tags=["tokens"])

# "sync" implies full pull/push; per-collection scopes gate future
# /items/* granularity. Anything else is rejected so invented scopes
# can never gain meaning later.
_VALID_SCOPES = {"sync"} | {
    f"{c}:{op}" for c in COLLECTIONS for op in ("read", "write")
}


@router.post("", response_model=ApiTokenCreated, status_code=201)
async def create_token(
    body: ApiTokenCreateIn,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    plaintext, prefix, digest = new_api_token()
    scopes = list(body.scopes or ["sync"])
    unknown = [s for s in scopes if s not in _VALID_SCOPES]
    if unknown:
        raise HTTPException(
            status_code=400, detail=f"Unknown scopes: {sorted(unknown)}"
        )
    row = ApiToken(
        user_id=user.id,
        name=body.name[:120],
        token_hash=digest,
        prefix=prefix,
        scopes=scopes,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ApiTokenCreated(
        id=row.id, name=row.name, prefix=row.prefix, scopes=row.scopes, token=plaintext
    )


@router.get("", response_model=list[ApiTokenOut])
async def list_tokens(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    rows = (
        await session.execute(
            select(ApiToken)
            .where(ApiToken.user_id == user.id, ApiToken.revoked.is_(False))
            .order_by(ApiToken.id.desc())
        )
    ).scalars()
    return [
        ApiTokenOut(id=r.id, name=r.name, prefix=r.prefix, scopes=r.scopes) for r in rows
    ]


@router.delete("/{token_id}", status_code=204)
async def revoke_token(
    token_id: int,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    row = await session.get(ApiToken, token_id)
    if row is None or row.user_id != user.id:
        return
    row.revoked = True
    await session.commit()
