"""In-app feedback: bug reports + feature requests without GitHub accounts.

Flow:
- Any signed-in app user POSTs a report. Trusted reporters (see
  TrustedReporter, managed by admins) file a GitHub issue immediately
  via the server token; everyone else lands in `pending`.
- Bugs file as `agent-approved`: approved and fixed automatically by
  the builder loop. Features file as `agent-pending`: they go through
  triage + manual approval before the builder touches them.
- Admins (ADMIN_EMAILS) review the queue in-app: approve (files the
  issue, optionally trusts the reporter for next time) or deny.
"""

from __future__ import annotations

import datetime as dt
import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..db import get_session
from ..deps import require_jwt_user
from ..github_issues import build_issue_body, create_issue
from ..models import FeedbackReport, TrustedReporter, User
from ..ratelimit import limit
from ..schemas import (
    FeedbackAdminOut,
    FeedbackApproveIn,
    FeedbackDenyIn,
    FeedbackOut,
    FeedbackStatusOut,
    FeedbackSubmitIn,
    TrustedAddIn,
    TrustedOut,
)

log = logging.getLogger("a_fish_in_sea.feedback")
router = APIRouter(prefix="/feedback", tags=["feedback"])


def _admin_emails() -> set[str]:
    raw = get_settings().admin_emails or ""
    return {e.strip().lower() for e in raw.split(",") if e.strip()}


def _is_admin(user: User) -> bool:
    return user.email.lower().strip() in _admin_emails()


def _require_admin(user: User) -> None:
    if not _is_admin(user):
        raise HTTPException(status_code=403, detail="Feedback admin only")


async def _is_trusted(session: AsyncSession, email: str) -> bool:
    row = (
        await session.execute(
            select(TrustedReporter).where(
                TrustedReporter.email == email.lower().strip()
            )
        )
    ).scalar_one_or_none()
    return row is not None


def _to_out(row: FeedbackReport) -> FeedbackOut:
    return FeedbackOut(
        id=row.id,
        kind=row.kind,
        title=row.title,
        description=row.description,
        device=row.device,
        extra=row.extra,
        status=row.status,
        github_issue_number=row.github_issue_number,
        github_issue_url=row.github_issue_url or "",
        deny_reason=row.deny_reason or "",
        created_at=row.created_at,
    )


def _to_admin_out(row: FeedbackReport) -> FeedbackAdminOut:
    return FeedbackAdminOut(
        **_to_out(row).model_dump(),
        email=row.email,
        reviewed_by=row.reviewed_by or "",
        reviewed_at=row.reviewed_at,
    )


async def _file_on_github(row: FeedbackReport) -> None:
    """Create the GitHub issue; on success mark filed, else record error."""
    s = get_settings()
    body = build_issue_body(
        kind=row.kind,
        description=row.description,
        device=row.device,
        extra=row.extra,
        reporter_email=row.email,
        app_platform=row.app_platform,
        app_version=row.app_version,
    )
    try:
        filed = await create_issue(
            repo=s.github_repo,
            token=s.github_token,
            kind=row.kind,
            title=row.title,
            body=body,
        )
    except Exception as e:  # API down / no token: stay pending, keep error
        row.github_error = str(e)[:500]
        log.warning("feedback #%d github file failed: %s", row.id, e)
        return
    row.status = "filed"
    row.github_issue_number = filed.number
    row.github_issue_url = filed.url
    row.github_error = ""


@router.get("/status", response_model=FeedbackStatusOut)
async def status(
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    admin = _is_admin(user)
    trusted = admin or await _is_trusted(session, user.email)
    return FeedbackStatusOut(is_admin=admin, is_trusted=trusted)


@router.post("", response_model=FeedbackOut, status_code=201)
async def submit(
    body: FeedbackSubmitIn,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("feedback:submit", 20, 3600, by_user=True)),
):
    row = FeedbackReport(
        user_id=user.id,
        email=user.email,
        kind=body.kind,
        title=body.title.strip(),
        description=body.description.strip(),
        device=body.device.strip(),
        extra=body.extra.strip(),
        app_platform=body.app_platform.strip(),
        app_version=body.app_version.strip(),
        status="pending",
    )
    session.add(row)
    await session.flush()  # need id for the github-error log line
    if _is_admin(user) or await _is_trusted(session, user.email):
        await _file_on_github(row)
    await session.commit()
    await session.refresh(row)
    return _to_out(row)


@router.get("/mine", response_model=list[FeedbackOut])
async def mine(
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    rows = (
        await session.execute(
            select(FeedbackReport)
            .where(FeedbackReport.user_id == user.id)
            .order_by(FeedbackReport.created_at.desc())
            .limit(200)
        )
    ).scalars()
    return [_to_out(r) for r in rows]


@router.get("/pending", response_model=list[FeedbackAdminOut])
async def pending(
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    _require_admin(user)
    rows = (
        await session.execute(
            select(FeedbackReport)
            .where(FeedbackReport.status == "pending")
            .order_by(FeedbackReport.created_at.asc())
            .limit(200)
        )
    ).scalars()
    return [_to_admin_out(r) for r in rows]


@router.post("/{report_id}/approve", response_model=FeedbackAdminOut)
async def approve(
    report_id: int,
    body: FeedbackApproveIn,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    _require_admin(user)
    row = await session.get(FeedbackReport, report_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Report not found")
    if row.status == "denied":
        raise HTTPException(
            status_code=409, detail="Report was denied; cannot approve"
        )
    if row.status != "filed":
        claim = await session.execute(
            update(FeedbackReport)
            .where(
                FeedbackReport.id == report_id,
                FeedbackReport.status == "pending",
            )
            .values(status="filing")
        )
        if (claim.rowcount or 0) != 1:
            await session.refresh(row)
            if row.status != "filed":
                raise HTTPException(
                    status_code=409, detail="Report is already being processed"
                )
        else:
            await session.flush()
            await _file_on_github(row)
            if row.status != "filed":
                row.status = "pending"
                await session.commit()
                await session.refresh(row)
                raise HTTPException(
                    status_code=502,
                    detail=f"GitHub filing failed: {row.github_error or 'unknown'}",
                )
    if body.trust_user and row.email:
        email = row.email.lower().strip()
        exists = (
            await session.execute(
                select(TrustedReporter).where(TrustedReporter.email == email)
            )
        ).scalar_one_or_none()
        if exists is None:
            session.add(TrustedReporter(email=email, added_by=user.email))
            try:
                await session.flush()
            except IntegrityError:
                await session.rollback()
                row = await session.get(FeedbackReport, report_id)
                assert row is not None
            else:
                log.warning(
                    "feedback trust granted: %s by admin %s (via approve #%d)",
                    email,
                    user.email,
                    row.id,
                )
    row.reviewed_by = user.email
    row.reviewed_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    await session.refresh(row)
    return _to_admin_out(row)


@router.post("/{report_id}/deny", response_model=FeedbackAdminOut)
async def deny(
    report_id: int,
    body: FeedbackDenyIn,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    _require_admin(user)
    row = await session.get(FeedbackReport, report_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Report not found")
    if row.status == "filed":
        raise HTTPException(
            status_code=409, detail="Already filed on GitHub; cannot deny"
        )
    row.status = "denied"
    row.deny_reason = body.reason.strip()
    row.reviewed_by = user.email
    row.reviewed_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    await session.refresh(row)
    return _to_admin_out(row)


@router.get("/trusted", response_model=list[TrustedOut])
async def trusted_list(
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    _require_admin(user)
    rows = (
        await session.execute(
            select(TrustedReporter).order_by(TrustedReporter.email.asc())
        )
    ).scalars()
    return [
        TrustedOut(email=r.email, added_by=r.added_by, created_at=r.created_at)
        for r in rows
    ]


@router.post("/trusted", response_model=TrustedOut, status_code=201)
async def trusted_add(
    body: TrustedAddIn,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    _require_admin(user)
    email = body.email.lower().strip()
    exists = (
        await session.execute(
            select(TrustedReporter).where(TrustedReporter.email == email)
        )
    ).scalar_one_or_none()
    if exists is not None:
        raise HTTPException(status_code=409, detail="Already trusted")
    row = TrustedReporter(email=email, added_by=user.email)
    session.add(row)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise HTTPException(status_code=409, detail="Already trusted")
    await session.refresh(row)
    log.warning("feedback trust granted: %s by admin %s (direct add)", email, user.email)
    return TrustedOut(
        email=row.email, added_by=row.added_by, created_at=row.created_at
    )


@router.delete("/trusted/{email}")
async def trusted_remove(
    email: str,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    _require_admin(user)
    row = (
        await session.execute(
            select(TrustedReporter).where(
                TrustedReporter.email == email.lower().strip()
            )
        )
    ).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Not a trusted reporter")
    await session.delete(row)
    await session.commit()
    log.warning(
        "feedback trust revoked: %s by admin %s", row.email, user.email
    )
    return {"status": "removed"}
