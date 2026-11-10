"""SQS order.confirmed -> one DynamoDB item per ticket.

Idempotent by construction: ticket_id is derived from (order_id, index) and the
put is conditional, so SQS redelivery (at-least-once) never duplicates tickets.
Uses ReportBatchItemFailures so one bad message doesn't retry the whole batch;
after maxReceiveCount failures a message lands in the DLQ (alarmed).
Only stdlib + the runtime's boto3: no packaging step.
"""

import hashlib
import hmac
import json
import logging
import os
from datetime import UTC, datetime

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

TABLE = boto3.resource("dynamodb").Table(os.environ["TICKETS_TABLE"])
# Public salt, it only makes codes look random; not a security control.
CODE_SALT = os.environ.get("CODE_SALT", "ticketrush").encode()


def seat_code(ticket_id: str) -> str:
    digest = hmac.new(CODE_SALT, ticket_id.encode(), hashlib.sha256).hexdigest().upper()
    return f"TR-{digest[:4]}-{digest[4:8]}"


def issue(order: dict) -> int:
    issued = 0
    now = datetime.now(UTC).isoformat()
    for i in range(int(order["quantity"])):
        ticket_id = f"{order['order_id']}#{i + 1}"
        try:
            TABLE.put_item(
                Item={
                    "user_id": order["user_id"],
                    "ticket_id": ticket_id,
                    "order_id": order["order_id"],
                    "event_id": order["event_id"],
                    "event_name": order.get("event_name", ""),
                    "seat_code": seat_code(ticket_id),
                    "issued_at": now,
                },
                ConditionExpression="attribute_not_exists(ticket_id)",
            )
            issued += 1
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise  # real failure -> message retried
    return issued


def handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        try:
            order = json.loads(record["body"])
            n = issue(order)
            log.info(json.dumps({"msg": "tickets issued", "order_id": order["order_id"], "issued": n}))
        except Exception:
            log.exception("failed to process message %s", record.get("messageId"))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
