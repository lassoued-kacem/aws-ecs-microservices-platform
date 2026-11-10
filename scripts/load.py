"""Tiny load generator: simulates a flash-sale drop so the dashboard has data.

usage: python scripts/load.py https://xxxx.cloudfront.net [buyers=60] [browse_seconds=120]
Each buyer registers, browses, and races to buy the 10-seat flash-drop event.
"""

import random
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import httpx

BASE = sys.argv[1].rstrip("/")
BUYERS = int(sys.argv[2]) if len(sys.argv) > 2 else 60
BROWSE = int(sys.argv[3]) if len(sys.argv) > 3 else 120


def buyer(i: int) -> str:
    with httpx.Client(base_url=BASE, timeout=10) as c:
        email = f"load-{uuid.uuid4().hex[:10]}@example.com"
        c.post("/api/auth/register", json={"email": email, "display_name": f"Buyer {i}", "password": "load-test-password-123"})
        events = c.get("/api/events").json()
        target = next((e for e in events if e["slug"] == "flash-drop-only-10"), random.choice(events))
        r = c.post(
            "/api/orders",
            json={"event_id": target["id"], "quantity": 1},
            headers={"Idempotency-Key": uuid.uuid4().hex},
        )
        return f"{r.status_code}"


def browse(deadline: float) -> int:
    n = 0
    with httpx.Client(base_url=BASE, timeout=10) as c:
        while time.time() < deadline:
            c.get("/api/events")
            c.get("/")
            n += 2
            time.sleep(random.uniform(0.05, 0.3))
    return n


if __name__ == "__main__":
    print(f"Flash sale: {BUYERS} buyers racing for 10 seats on {BASE}")
    with ThreadPoolExecutor(max_workers=30) as pool:
        results = list(pool.map(buyer, range(BUYERS)))
    print({code: results.count(code) for code in set(results)}, "(201 = bought, 409 = sold out)")
    print(f"Browsing traffic for {BROWSE}s...")
    deadline = time.time() + BROWSE
    with ThreadPoolExecutor(max_workers=10) as pool:
        total = sum(pool.map(browse, [deadline] * 10))
    print(f"Sent {total} browse requests.")
