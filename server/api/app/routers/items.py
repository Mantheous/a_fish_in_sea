"""Per-collection convenience CRUD for MCP agents and debugging.

Thin wrappers over the sync envelope: MCP tools that only need "my tasks"
or "create an event" don't have to speak raw pull/push. Writes go through
the same SyncItem rows, so web/mobile pick them up on next pull.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import require_scope
from ..models import COLLECTIONS, SyncItem, User
from ..schemas import ItemUpsertIn, SyncRecord

router = APIRouter(prefix="/items", tags=["items"])


def _check_collection(collection: str) -> None:
    """Reject unknown collections: without this, any authenticated user
    could write arbitrary collection names into the sync envelope,
    bypassing the allowlist enforced by /sync/push."""
    if collection not in COLLECTIONS:
        raise HTTPException(
            status_code=400, detail=f"Unknown collection: {collection}"
        )


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _to_record(row: SyncItem) -> SyncRecord:
    return SyncRecord(
        collection=row.collection,
        item_id=row.item_id,
        data=row.data if isinstance(row.data, dict) else {},
        deleted=row.deleted,
        rev=row.rev,
        updated_at=row.updated_at,
    )


async def _get_row(
    session: AsyncSession, user_id: int, collection: str, item_id: str
) -> SyncItem | None:
    return (
        await session.execute(
            select(SyncItem).where(
                and_(
                    SyncItem.user_id == user_id,
                    SyncItem.collection == collection,
                    SyncItem.item_id == item_id,
                    SyncItem.deleted.is_(False),
                )
            )
        )
    ).scalar_one_or_none()


@router.get("/{collection}", response_model=list[SyncRecord])
async def list_items(
    collection: str,
    user: User = Depends(require_scope("sync")),
    session: AsyncSession = Depends(get_session),
):
    _check_collection(collection)
    rows = (
        await session.execute(
            select(SyncItem)
            .where(
                and_(
                    SyncItem.user_id == user.id,
                    SyncItem.collection == collection,
                    SyncItem.deleted.is_(False),
                )
            )
            .order_by(SyncItem.updated_at.desc())
            .limit(1000)
        )
    ).scalars()
    return [_to_record(r) for r in rows]


@router.get("/{collection}/{item_id}", response_model=SyncRecord)
async def get_item(
    collection: str,
    item_id: str,
    user: User = Depends(require_scope("sync")),
    session: AsyncSession = Depends(get_session),
):
    _check_collection(collection)
    row = await _get_row(session, user.id, collection, item_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Not found")
    return _to_record(row)


@router.put("/{collection}/{item_id}", response_model=SyncRecord)
async def put_item(
    collection: str,
    item_id: str,
    body: ItemUpsertIn,
    user: User = Depends(require_scope("sync")),
    session: AsyncSession = Depends(get_session),
):
    _check_collection(collection)
    now = _now()
    data = dict(body.data)
    data.setdefault("id", item_id)
    row = (
        await session.execute(
            select(SyncItem).where(
                and_(
                    SyncItem.user_id == user.id,
                    SyncItem.collection == collection,
                    SyncItem.item_id == item_id,
                )
            )
        )
    ).scalar_one_or_none()
    if row is None:
        row = SyncItem(
            user_id=user.id,
            collection=collection,
            item_id=item_id,
            data=data,
            rev=1,
            updated_at=now,
        )
        session.add(row)
    else:
        row.data = data
        row.deleted = False
        row.rev += 1
        row.updated_at = now
    await session.commit()
    await session.refresh(row)
    return _to_record(row)


@router.post("/{collection}", response_model=SyncRecord, status_code=201)
async def create_item(
    collection: str,
    body: ItemUpsertIn,
    user: User = Depends(require_scope("sync")),
    session: AsyncSession = Depends(get_session),
):
    _check_collection(collection)
    item_id = str(body.data.get("id") or uuid.uuid4())
    return await put_item(collection, item_id, body, user, session)


@router.delete("/{collection}/{item_id}", response_model=SyncRecord)
async def delete_item(
    collection: str,
    item_id: str,
    user: User = Depends(require_scope("sync")),
    session: AsyncSession = Depends(get_session),
):
    _check_collection(collection)
    row = (
        await session.execute(
            select(SyncItem).where(
                and_(
                    SyncItem.user_id == user.id,
                    SyncItem.collection == collection,
                    SyncItem.item_id == item_id,
                )
            )
        )
    ).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Not found")
    row.deleted = True
    row.rev += 1
    row.updated_at = _now()
    await session.commit()
    await session.refresh(row)
    return _to_record(row)
