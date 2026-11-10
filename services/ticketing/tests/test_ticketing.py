import uuid
from concurrent.futures import ThreadPoolExecutor

from app import cache
from app.db import engine
from app.main import EVENTS_KEY, event_key
from sqlalchemy import text

from tests.conftest import make_token


def _new_event(capacity: int) -> str:
    eid = uuid.uuid4()
    with engine.begin() as c:
        c.execute(
            text(
                "INSERT INTO ticketing.events (id, slug, name, artist, venue, city, starts_at, price_cents, capacity, available, hue) "
                "VALUES (:id, :slug, 'Test', 'A', 'V', 'C', now() + interval '10 days', 1000, :cap, :cap, 10)"
            ),
            {"id": eid, "slug": f"t-{eid.hex[:12]}", "cap": capacity},
        )
    cache.delete(EVENTS_KEY)
    return str(eid)


def _buy(client, eid, qty=1, token=None, key=None):
    return client.post(
        "/api/orders",
        json={"event_id": eid, "quantity": qty},
        headers={"Authorization": f"Bearer {token or make_token()}", "Idempotency-Key": key or uuid.uuid4().hex},
    )


def test_seeded_events_listed(client):
    events = client.get("/api/events").json()
    assert len(events) >= 8
    assert any(e["slug"] == "flash-drop-only-10" for e in events)


def test_requires_auth(client):
    r = client.post("/api/orders", json={"event_id": str(uuid.uuid4()), "quantity": 1}, headers={"Idempotency-Key": "abcdefgh"})
    assert r.status_code == 401


def test_buy_decrements_and_invalidates_cache(client):
    eid = _new_event(5)
    assert client.get(f"/api/events/{eid}").json()["available"] == 5
    r = _buy(client, eid, 2)
    assert r.status_code == 201, r.text
    assert r.json()["total_cents"] == 2000
    assert cache.get_json(event_key(eid)) is None
    assert client.get(f"/api/events/{eid}").json()["available"] == 3


def test_idempotent_retry_returns_same_order(client):
    eid = _new_event(5)
    token, key = make_token(), uuid.uuid4().hex
    a = _buy(client, eid, 1, token, key)
    b = _buy(client, eid, 1, token, key)
    assert a.status_code == b.status_code == 201
    assert a.json()["id"] == b.json()["id"]
    assert client.get(f"/api/events/{eid}").json()["available"] == 4


def test_per_user_limit(client):
    eid = _new_event(50)
    token = make_token()
    assert _buy(client, eid, 6, token).status_code == 201
    assert _buy(client, eid, 1, token).status_code == 409


def test_no_oversell_under_concurrency(client):
    """40 buyers race for 10 seats: exactly 10 orders win, inventory hits 0, never negative."""
    eid = _new_event(10)
    with ThreadPoolExecutor(max_workers=20) as pool:
        codes = list(pool.map(lambda _: _buy(client, eid, 1).status_code, range(40)))
    assert codes.count(201) == 10
    assert codes.count(409) == 30
    with engine.connect() as c:
        assert c.execute(text("SELECT available FROM ticketing.events WHERE id = :id"), {"id": eid}).scalar() == 0
        assert c.execute(text("SELECT count(*) FROM ticketing.orders WHERE event_id = :id"), {"id": eid}).scalar() == 10


def test_unknown_event_404(client):
    assert _buy(client, str(uuid.uuid4())).status_code == 404
    assert client.get("/api/events/not-a-uuid").status_code == 404


def test_my_orders(client):
    eid = _new_event(5)
    token = make_token()
    _buy(client, eid, 1, token)
    orders = client.get("/api/orders", headers={"Authorization": f"Bearer {token}"}).json()
    assert len(orders) == 1 and orders[0]["event_name"] == "Test"
