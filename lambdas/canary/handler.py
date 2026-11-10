"""External synthetic canary: probes the public CloudFront URL every minute
from OUTSIDE the VPC (what a user sees), and emits CloudWatch metrics via
Embedded Metric Format (a print() becomes a metric; no PutMetricData call).
This is the availability SLI the SLOs will be built on.
"""

import json
import os
import time
import urllib.error
import urllib.request

BASE = os.environ["TARGET_BASE_URL"].rstrip("/")
if not BASE.startswith("https://"):
    raise ValueError("TARGET_BASE_URL must be https://")
NAMESPACE = os.environ.get("METRICS_NAMESPACE", "TicketRush/Canary")
CHECKS = {
    "frontend": "/",
    "events_api": "/api/events",
    "identity_api": "/api/auth/health",
    "ticketing_api": "/api/health",
}


def probe(path: str) -> tuple[int, float]:
    start = time.perf_counter()
    headers = {"User-Agent": "ticketrush-canary/1.0"}
    req = urllib.request.Request(BASE + path, headers=headers)  # noqa: S310 (scheme validated at import)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:  # noqa: S310 (https URL from config)
            resp.read(1024)
            ok = 1 if 200 <= resp.status < 300 else 0
    except (urllib.error.URLError, TimeoutError):
        ok = 0
    return ok, (time.perf_counter() - start) * 1000


def handler(_event, _context):
    results = {}
    for check, path in CHECKS.items():
        ok, ms = probe(path)
        results[check] = ok
        print(
            json.dumps(
                {
                    "_aws": {
                        "Timestamp": int(time.time() * 1000),
                        "CloudWatchMetrics": [
                            {
                                "Namespace": NAMESPACE,
                                "Dimensions": [["Check"]],
                                "Metrics": [{"Name": "Success", "Unit": "Count"}, {"Name": "LatencyMs", "Unit": "Milliseconds"}],
                            }
                        ],
                    },
                    "Check": check,
                    "Success": ok,
                    "LatencyMs": round(ms, 1),
                }
            )
        )
    return results
