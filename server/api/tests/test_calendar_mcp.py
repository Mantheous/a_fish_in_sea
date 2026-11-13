"""MCP protocol, authorization, safe writes and sync visibility."""
import json
import os
import tempfile
import uuid

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/mcp.db")
os.environ.setdefault("JWT_SECRET", "test-secret")

from app.main import create_app  # noqa: E402


@pytest.fixture
def client():
    with TestClient(create_app(), base_url="http://localhost",
                    headers={"X-Forwarded-For": f"mcp-test-{uuid.uuid4().hex}"}) as c:
        yield c


def account(client):
    r = client.post("/api/v1/auth/register", json={
        "email": f"mcp-{uuid.uuid4().hex}@example.com", "password": "password123"})
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def key(client, jwt, scopes=None, review=False):
    r = client.post("/api/v1/tokens", headers=jwt, json={
        "name": "Muse", "scopes": scopes or ["calendar:write"], "review": review})
    assert r.status_code == 201
    return {"Authorization": f"Bearer {r.json()['token']}"}, r.json()["id"]


def rpc(client, h, method, params=None, path="/mcp/"):
    return client.post(path, headers={**h, "Accept": "application/json, text/event-stream"},
        json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def tool(client, h, name, **args):
    r = rpc(client, h, "tools/call", {"name": name, "arguments": args})
    assert r.status_code == 200, r.text
    result = r.json()["result"]
    return result if result.get("isError") else json.loads(result["content"][0]["text"])


def event(**extra):
    return {"subject": "MCP test", "start": "2026-11-12T09:00:00-07:00",
            "end": "2026-11-12T10:00:00-07:00", **extra}


TZ = {"timezone": "America/Denver"}
RANGE = {"start": "2026-11-12T00:00:00-07:00", "end": "2026-11-13T00:00:00-07:00", **TZ}


def test_protocol_discovery_and_fish_prefix(client):
    token, _ = key(client, account(client))
    for path in ("/mcp/", "/fish/mcp/"):
        r = rpc(client, token, "initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "Muse test", "version": "1"}}, path=path)
        assert r.status_code == 200, r.text
        assert r.json()["result"]["serverInfo"]["name"] == "A Fish in Sea Calendar"
        assert r.headers["cache-control"] == "no-store"
        assert "mcp-session-id" not in r.headers
    tools = {t["name"]: t for t in rpc(client, token, "tools/list").json()["result"]["tools"]}
    assert set(tools) == {"list_calendars", "list_events", "get_event", "create_event", "update_event", "delete_event"}
    assert tools["get_event"]["annotations"]["readOnlyHint"]
    assert tools["delete_event"]["annotations"]["destructiveHint"]


def test_auth_scope_review_revocation_and_origin(client):
    jwt = account(client)
    token, token_id = key(client, jwt)
    for h in ({}, {"Authorization": "Bearer invalid"}):
        assert rpc(client, h, "tools/list").status_code == 401
        assert client.get("/mcp/", headers=h).status_code == 401
    wrong, _ = key(client, jwt, ["nodes:read"])
    review, _ = key(client, jwt, review=True)
    assert rpc(client, wrong, "tools/list").status_code == 403
    assert rpc(client, review, "tools/list").status_code == 403
    assert rpc(client, {**token, "Origin": "https://evil.example"}, "tools/list").status_code == 403
    assert rpc(client, {**token, "Host": "evil.example"}, "tools/list").status_code == 421
    client.delete(f"/api/v1/tokens/{token_id}", headers=jwt)
    assert rpc(client, token, "tools/list").status_code == 401


def test_roundtrip_patch_conflict_delete_and_account_isolation(client):
    jwt = account(client)
    token, _ = key(client, jwt)
    other, _ = key(client, account(client))
    created = tool(client, token, "create_event", event=event(), **TZ)
    eid = created["event_id"]
    assert tool(client, other, "get_event", event_id=eid, **TZ)["isError"]
    assert tool(client, other, "list_events", **RANGE)["events"] == []
    assert tool(client, other, "update_event", event_id=eid, revision=1,
                changes={"subject": "wrong user"}, **TZ)["isError"]
    assert tool(client, other, "delete_event", event_id=eid, revision=1, **TZ)["isError"]
    data = created["event"] | {"sessions": [{"start": "2026-11-12T16:00:00Z"}], "futureField": "keep"}
    r = client.put(f"/api/v1/items/events/{eid}", headers=jwt, json={"data": data})
    rev = r.json()["rev"]
    changed = tool(client, token, "update_event", event_id=eid, revision=rev,
                   changes={"notes": "Updated", "location": None}, **TZ)
    assert changed["event"]["futureField"] == "keep"
    assert changed["event"]["sessions"] == data["sessions"]
    assert changed["event"]["subject"] == "MCP test"
    assert tool(client, token, "update_event", event_id=eid, revision=rev,
                changes={"subject": "stale"}, **TZ)["isError"]
    assert tool(client, token, "delete_event", event_id=eid, revision=rev, **TZ)["isError"]
    pulled = client.get("/api/v1/sync/pull", headers=jwt).json()["changes"]
    assert any(c["item_id"] == eid and c["data"]["notes"] == "Updated" for c in pulled)
    assert tool(client, token, "delete_event", event_id=eid, revision=changed["revision"], **TZ)["deleted"]
    assert tool(client, token, "list_events", **RANGE)["events"] == []
    pulled = client.get("/api/v1/sync/pull", headers=jwt).json()["changes"]
    assert any(c["item_id"] == eid and c["deleted"] for c in pulled)


def test_readonly_scopes_and_secret_free_feeds(client):
    jwt = account(client)
    writer, _ = key(client, jwt)
    reader, _ = key(client, jwt, ["calendar:read"])
    narrow, _ = key(client, jwt, ["events:read"])
    created = tool(client, writer, "create_event", event=event(), **TZ)
    assert len(tool(client, reader, "list_events", **RANGE)["events"]) == 1
    assert tool(client, reader, "create_event", event=event(), **TZ)["isError"]
    assert tool(client, reader, "update_event", event_id=created["event_id"], revision=1,
                changes={"subject": "no"}, **TZ)["isError"]
    assert tool(client, reader, "delete_event", event_id=created["event_id"], revision=1, **TZ)["isError"]
    assert tool(client, narrow, "list_calendars")["isError"]
    client.put("/api/v1/items/feeds/google", headers=jwt, json={"data": {
        "name": "Work", "kind": "google", "url": "https://secret.example/private-token"}})
    calendars = tool(client, reader, "list_calendars")
    assert "private-token" not in json.dumps(calendars)
    assert calendars["calendars"][1]["writable"] is False
    assert client.get("/api/v1/items/transactions", headers=writer).status_code == 403
    assert client.get("/api/v1/items/feeds", headers=writer).status_code == 403
    assert client.put("/api/v1/items/events/raw-bypass", headers=writer,
                      json={"data": event()}).status_code == 403
    assert client.post("/api/v1/tokens", headers=writer, json={"name": "escalate"}).status_code == 403


@pytest.mark.parametrize("patch", [{"feedId": "gcal:1"}, {"subject": None}, {"subject": " "},
    {"start": "2026-11-12T12:00:00"}, {"start": "2026-11-12T12:00:00-07:00"}, {"allDay": "false"}])
def test_invalid_input_does_not_write(client, patch):
    token, _ = key(client, account(client))
    assert tool(client, token, "create_event", event=event(**patch), **TZ)["isError"]
    assert tool(client, token, "list_events", **RANGE)["events"] == []


@pytest.mark.parametrize("protected", [{"feedId": "gcal:1"}, {"taskId": "goal"}, {"recurrenceRule": "FREQ=DAILY"}])
def test_imported_linked_and_recurring_events_are_readable_but_not_mutable(client, protected):
    jwt = account(client)
    token, _ = key(client, jwt)
    r = client.post("/api/v1/items/events", headers=jwt, json={"data": event(**protected)})
    eid = r.json()["item_id"]
    assert tool(client, token, "get_event", event_id=eid, **TZ)["event"]["subject"] == "MCP test"
    assert tool(client, token, "update_event", event_id=eid, revision=1,
                changes={"subject": "no"}, **TZ)["isError"]
    assert tool(client, token, "delete_event", event_id=eid, revision=1, **TZ)["isError"]


def test_pagination_legacy_local_times_overlap_and_invalid_rows(client):
    jwt = account(client)
    token, _ = key(client, jwt)
    for data in [event(start="2026-11-12T09:00:00", end="2026-11-12T10:00:00"),
                 event(start="2026-11-11T23:00:00-07:00", end="2026-11-12T01:00:00-07:00"),
                 {"subject": "damaged"}, event(start="2026-11-14T09:00:00-07:00", end="2026-11-14T10:00:00-07:00")]:
        client.post("/api/v1/items/events", headers=jwt, json={"data": data})
    first = tool(client, token, "list_events", limit=1, **RANGE)
    second = tool(client, token, "list_events", limit=1, cursor=first["next_cursor"], **RANGE)
    last = tool(client, token, "list_events", cursor=second["next_cursor"], **RANGE)
    assert first["events"][0]["event"]["start"] == "2026-11-12T09:00:00-07:00"
    assert len(second["events"]) == 1
    assert last["events"] == [] and last["next_cursor"] is None
    assert last["skipped_invalid"] == 1


def test_all_day_event_overlaps_afternoon_and_timezone_dst(client):
    jwt = account(client)
    token, _ = key(client, jwt)
    tool(client, token, "create_event", event=event(
        start="2026-11-12T00:00:00-07:00", end="2026-11-12T00:00:00-07:00", allDay=True), **TZ)
    assert len(tool(client, token, "list_events", **(RANGE | {"start": "2026-11-12T12:00:00-07:00"}))["events"]) == 1
    r = client.post("/api/v1/items/events", headers=jwt, json={"data": event(
        start="2026-07-01T09:00:00", end="2026-07-01T10:00:00")})
    got = tool(client, token, "get_event", event_id=r.json()["item_id"], **TZ)
    assert got["event"]["start"].endswith("-06:00")


def test_empty_scan_page_has_continuation_and_body_is_bounded(client):
    jwt = account(client)
    token, _ = key(client, jwt)
    changes = [{"collection": "events", "item_id": f"e{i}", "data": event(
        start="2026-11-14T09:00:00-07:00", end="2026-11-14T10:00:00-07:00")} for i in range(500)]
    changes.append({"collection": "events", "item_id": "last", "data": event()})
    assert client.post("/api/v1/sync/push", headers=jwt, json={"changes": changes}).status_code == 200
    first = tool(client, token, "list_events", **RANGE)
    assert first["events"] == [] and first["next_cursor"] is not None
    last = tool(client, token, "list_events", cursor=first["next_cursor"], **RANGE)
    assert last["events"][0]["event_id"] == "last" and last["next_cursor"] is None
    r = rpc(client, token, "tools/call", {"name": "create_event", "arguments": {
        "event": event(notes="x" * 300000), **TZ}})
    assert r.status_code == 413


@pytest.mark.asyncio
async def test_official_mcp_client_connects():
    import httpx
    from mcp import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    app = create_app()
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url="http://localhost",
                                      headers={"X-Forwarded-For": f"sdk-test-{uuid.uuid4().hex}"}) as http:
            r = await http.post("/api/v1/auth/register", json={
                "email": f"sdk-{uuid.uuid4().hex}@example.com", "password": "password123"})
            http.headers["Authorization"] = f"Bearer {r.json()['access_token']}"
            r = await http.post("/api/v1/tokens", json={"name": "SDK", "scopes": ["events:read", "feeds:read"]})
            http.headers["Authorization"] = f"Bearer {r.json()['token']}"
            async with streamable_http_client("http://localhost/mcp/", http_client=http) as (read, write, _):
                async with ClientSession(read, write) as session:
                    initialized = await session.initialize()
                    assert initialized.serverInfo.name == "A Fish in Sea Calendar"
                    tools = await session.list_tools()
                    assert len(tools.tools) == 6
                    result = await session.call_tool("list_calendars", {})
                    assert not result.isError
                    assert json.loads(result.content[0].text)["calendars"][0]["id"] == "personal"
