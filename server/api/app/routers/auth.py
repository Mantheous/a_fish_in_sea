from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import get_current_user
from ..models import User
from ..ratelimit import limit
from ..refresh_store import (
    InvalidRefresh,
    ReusedRefresh,
    issue,
    redeem,
    revoke_all,
    revoke_one,
)
from ..schemas import LoginIn, LogoutIn, MeOut, RefreshIn, RegisterIn, TokenPair
from ..security import (
    access_token,
    hash_password,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["auth"])

# Bcrypt hash of a random never-used password, computed once at import.
# Verified against (and discarded) when the email is unknown so login
# timing doesn't reveal whether an account exists. Generated rather
# than hardcoded so it is always a valid hash for the active scheme.
_DUMMY_HASH = hash_password("dummy-never-matches-" + "x" * 32)


@router.post("/register", response_model=TokenPair, status_code=201)
async def register(
    body: RegisterIn,
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("auth:register", 120, 60)),
):
    email = body.email.lower().strip()
    existing = (
        await session.execute(select(User).where(User.email == email))
    ).scalar_one_or_none()
    if existing is not None:
        raise HTTPException(status_code=409, detail="Email already registered")
    user = User(email=email, password_hash=hash_password(body.password))
    session.add(user)
    await session.commit()
    await session.refresh(user)
    refresh, _jti = await issue(session, user.id)
    return TokenPair(access_token=access_token(user.id), refresh_token=refresh)


@router.post("/login", response_model=TokenPair)
async def login(
    body: LoginIn,
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("auth:login", 20, 60)),
):
    email = body.email.lower().strip()
    user = (
        await session.execute(select(User).where(User.email == email))
    ).scalar_one_or_none()
    if user is None:
        # Same work as a real check: don't leak account existence via
        # response time.
        verify_password(body.password, _DUMMY_HASH)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials"
        )
    if not verify_password(body.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials"
        )
    refresh, _jti = await issue(session, user.id)
    return TokenPair(access_token=access_token(user.id), refresh_token=refresh)


@router.post("/refresh", response_model=TokenPair)
async def refresh(
    body: RefreshIn,
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("auth:refresh", 120, 60)),
):
    """Rotate the refresh token: the presented token is revoked and a
    successor is issued. Reuse of a revoked token revokes the whole
    family (theft response) and still answers 401."""
    try:
        user_id, new_refresh = await redeem(session, body.refresh_token)
    except (InvalidRefresh, ReusedRefresh):
        raise HTTPException(status_code=401, detail="Invalid refresh token")
    return TokenPair(
        access_token=access_token(user_id), refresh_token=new_refresh
    )


@router.post("/logout")
async def logout(
    body: LogoutIn,
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("auth:logout", 60, 60)),
):
    """Revoke one refresh token. Always answers 200 so logout can't be
    used to probe token validity."""
    await revoke_one(session, body.refresh_token)
    return {"status": "logged out"}


@router.post("/logout_all")
async def logout_all(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Revoke all of the caller's refresh tokens (all devices)."""
    await revoke_all(session, user.id)
    return {"status": "logged out"}


@router.get("/me", response_model=MeOut)
async def me(user: User = Depends(get_current_user)):
    return MeOut(id=user.id, email=user.email)
