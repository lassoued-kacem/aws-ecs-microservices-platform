"""SQS (order events) and DynamoDB (issued tickets). Disabled when not configured."""

import json
import logging
import time
from functools import lru_cache

import boto3
from boto3.dynamodb.conditions import Key

from .config import get_settings

log = logging.getLogger(__name__)


@lru_cache
def _session():
    return boto3.session.Session(region_name=get_settings().aws_region)


def _kw():
    s = get_settings()
    return {"endpoint_url": s.aws_endpoint_url} if s.aws_endpoint_url else {}


def publish_order_confirmed(payload: dict) -> bool:
    s = get_settings()
    if not s.orders_queue_url:
        return False
    try:
        _session().client("sqs", **_kw()).send_message(
            QueueUrl=s.orders_queue_url,
            MessageBody=json.dumps(payload, default=str),
            MessageAttributes={"type": {"DataType": "String", "StringValue": "order.confirmed"}},
        )
        return True
    except Exception:
        # Known limitation, documented: a transactional outbox would close this gap.
        log.exception("failed to publish order event")
        return False


def list_tickets(user_id: str) -> list[dict]:
    s = get_settings()
    if not s.tickets_table:
        return []
    table = _session().resource("dynamodb", **_kw()).Table(s.tickets_table)
    resp = table.query(KeyConditionExpression=Key("user_id").eq(user_id), Limit=200)
    return resp.get("Items", [])


def emit_metric(name: str, value: float, unit: str = "Count", **dims: str) -> None:
    """CloudWatch Embedded Metric Format: a JSON log line becomes a metric. No API call."""
    s = get_settings()
    dims = {"Service": s.service_name, **dims}
    print(
        json.dumps(
            {
                "_aws": {
                    "Timestamp": int(time.time() * 1000),
                    "CloudWatchMetrics": [
                        {
                            "Namespace": s.metrics_namespace,
                            "Dimensions": [list(dims.keys())],
                            "Metrics": [{"Name": name, "Unit": unit}],
                        }
                    ],
                },
                name: value,
                **dims,
            }
        ),
        flush=True,
    )
