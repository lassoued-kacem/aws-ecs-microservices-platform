import importlib
import json
import os
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ticket_issuer"))


@pytest.fixture
def table():
    os.environ.update(AWS_DEFAULT_REGION="eu-west-3", TICKETS_TABLE="tickets", AWS_ACCESS_KEY_ID="x", AWS_SECRET_ACCESS_KEY="x")
    with mock_aws():
        t = boto3.resource("dynamodb").create_table(
            TableName="tickets",
            KeySchema=[{"AttributeName": "user_id", "KeyType": "HASH"}, {"AttributeName": "ticket_id", "KeyType": "RANGE"}],
            AttributeDefinitions=[{"AttributeName": "user_id", "AttributeType": "S"}, {"AttributeName": "ticket_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        import handler

        importlib.reload(handler)
        yield t, handler


def _event(*bodies):
    return {"Records": [{"messageId": f"m{i}", "body": b if isinstance(b, str) else json.dumps(b)} for i, b in enumerate(bodies)]}


ORDER = {"order_id": "o1", "user_id": "u1", "event_id": "e1", "event_name": "Show", "quantity": 3}


def test_issues_one_item_per_ticket(table):
    t, h = table
    assert h.handler(_event(ORDER), None) == {"batchItemFailures": []}
    assert t.scan()["Count"] == 3


def test_redelivery_is_idempotent(table):
    t, h = table
    h.handler(_event(ORDER), None)
    h.handler(_event(ORDER), None)
    assert t.scan()["Count"] == 3


def test_bad_message_reported_individually(table):
    t, h = table
    out = h.handler(_event("not json", ORDER), None)
    assert out == {"batchItemFailures": [{"itemIdentifier": "m0"}]}
    assert t.scan()["Count"] == 3
