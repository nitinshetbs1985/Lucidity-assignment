"""SNS-to-Slack notifier for CloudWatch alarm notifications.

The Slack incoming-webhook URL is read from AWS Secrets Manager. The secret can
be either a plain URL string or JSON containing the configured key.
"""
import json
import logging
import os
import urllib.request
import boto3

LOG = logging.getLogger()
LOG.setLevel(os.getenv("LOG_LEVEL", "INFO"))
SECRETS = boto3.client("secretsmanager")
_cached_webhook = None


def _webhook_url():
    global _cached_webhook
    if _cached_webhook:
        return _cached_webhook
    response = SECRETS.get_secret_value(SecretId=os.environ["SLACK_SECRET_ARN"])
    raw = response.get("SecretString")
    if not raw:
        raise ValueError("Slack secret must contain SecretString")
    key = os.getenv("SLACK_SECRET_JSON_KEY", "webhook_url")
    try:
        parsed = json.loads(raw)
        _cached_webhook = parsed[key] if isinstance(parsed, dict) else parsed
    except json.JSONDecodeError:
        _cached_webhook = raw
    if not isinstance(_cached_webhook, str) or not _cached_webhook.startswith("https://"):
        raise ValueError("Slack webhook secret is not a valid HTTPS URL")
    return _cached_webhook


def _format_alarm(message):
    try:
        alarm = json.loads(message)
    except json.JSONDecodeError:
        return {"text": f"AWS monitoring notification\n```{message[:2500]}```"}

    name = alarm.get("AlarmName", "CloudWatch alarm")
    state = alarm.get("NewStateValue", "UNKNOWN")
    reason = alarm.get("NewStateReason", "No reason supplied")
    region = alarm.get("Region", "Unknown region")
    account = alarm.get("AWSAccountId", "Unknown account")
    icon = {"ALARM": ":rotating_light:", "OK": ":white_check_mark:"}.get(state, ":warning:")
    return {
        "text": f"{icon} {name} is {state}",
        "blocks": [
            {"type": "header", "text": {"type": "plain_text", "text": f"{name}: {state}", "emoji": True}},
            {"type": "section", "fields": [
                {"type": "mrkdwn", "text": f"*Account*\n{account}"},
                {"type": "mrkdwn", "text": f"*Region*\n{region}"}
            ]},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"*Reason*\n{reason[:2500]}"}}
        ]
    }


def lambda_handler(event, context):
    failures = []
    for record in event.get("Records", []):
        try:
            message = record["Sns"]["Message"]
            payload = _format_alarm(message)
            request = urllib.request.Request(
                _webhook_url(),
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=10) as response:
                if not 200 <= response.status < 300:
                    raise RuntimeError(f"Slack returned HTTP {response.status}")
            LOG.info("Notification delivered for SNS message %s", record["Sns"].get("MessageId"))
        except Exception as exc:
            LOG.exception("Notification delivery failed")
            failures.append(str(exc))
    if failures:
        raise RuntimeError("; ".join(failures))
    return {"processed": len(event.get("Records", []))}
