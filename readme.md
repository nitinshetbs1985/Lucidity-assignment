# Centralized EC2 Disk Utilization Monitoring

Monitor disk usage across all your Linux EC2 instances from a single AWS account. Systems Manager installs and configures the CloudWatch Agent on each enrolled instance. CloudWatch cross-account observability (OAM) shares metrics with a central monitoring account, where a dashboard, fleet-level alarms, and a Slack notifier give you a single pane of glass.

**What you get:**
- A CloudWatch dashboard showing disk utilization per account, instance, and filesystem path
- Fleet-level warning (80%) and critical (90%) alarms with configurable thresholds
- Slack and optional email notifications via SNS + Lambda
- Ansible playbooks for legacy hosts that cannot use SSM

---

## How it works

```
Member account (each)                        Monitoring account
┌──────────────────────────────────┐         ┌────────────────────────────────────────┐
│  EC2 instance                    │         │  CloudWatch dashboard                  │
│  └─ IAM instance profile         │         │  Fleet alarms (warning / critical)     │
│  └─ SSM Agent                    │──OAM──▶ │  SNS topic → Lambda → Slack           │
│     └─ Installs CloudWatch Agent │         │  OAM sink (receives shared metrics)    │
│  └─ CloudWatch Agent             │         └────────────────────────────────────────┘
│     └─ Publishes disk_used_%     │
└──────────────────────────────────┘
```

Metric flow: `CloudWatch Agent → CWAgent namespace → OAM link → monitoring account → alarms → SNS → Lambda → Slack`

---

## Prerequisites checklist

Complete everything below before starting deployment.

- [ ] **AWS Organization** — you have an AWS Organization and a dedicated monitoring account.
- [ ] **StackSets trusted access** — enable trusted access for CloudFormation StackSets in your Organizations management account (required for service-managed StackSets).
- [ ] **AWS CLI v2** — installed and configured with credentials for the monitoring account and the management/delegated-admin account.
- [ ] **Slack incoming webhook** — create one in Slack and have the URL ready. Do not commit it to source control.
- [ ] **Notification email** — optional, for SNS email alerts alongside Slack.
- [ ] **EC2 network access** — target instances can reach SSM, CloudWatch, and S3 endpoints via NAT, internet, or VPC interface endpoints.

> **For Ansible (optional):** Python 3, Ansible Core ≥ 2.14, the `amazon.aws` collection, and SSH/network access to legacy hosts.

---

## Deployment

### Step 0 — Set shell variables

Run these once in your terminal. All commands in the steps below reference these variables so nothing is hardcoded.

```bash
export MONITORING_ACCOUNT_REGION="us-east-1"                # region for the monitoring stack
export MONITORING_STACK_NAME="central-disk-monitoring"       # name for the monitoring stack
export MEMBER_STACKSET_NAME="central-disk-monitoring-member" # name for the member StackSet
export ORG_ID="o-example12345"                               # your AWS Organizations ID
export OU_ID="ou-xxxx-yyyyyyyy"                              # target OU for member accounts
export NOTIFICATION_EMAIL="operations@example.com"           # leave empty ("") to skip email
export SLACK_SECRET_NAME="central-monitoring/slack-webhook"  # Secrets Manager secret name
```

---

### Step 1 — Store the Slack webhook in Secrets Manager

Create a local file called `slack-secret.json`:

```json
{"webhook_url":"https://hooks.slack.com/services/REPLACE/ME"}
```

Create the secret in the monitoring account:

```bash
aws secretsmanager create-secret \
  --name "$SLACK_SECRET_NAME" \
  --secret-string file://slack-secret.json \
  --region "$MONITORING_ACCOUNT_REGION"
```

Retrieve and store the secret ARN for use in Step 2:

```bash
SLACK_SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "$SLACK_SECRET_NAME" \
  --query ARN --output text \
  --region "$MONITORING_ACCOUNT_REGION")
echo "$SLACK_SECRET_ARN"
```

> **Tip:** Delete `slack-secret.json` after this step. The URL is now safely stored in Secrets Manager and is no longer needed locally.

---

### Step 2 — Deploy the monitoring account stack

This stack creates the OAM sink, CloudWatch dashboard, alarms, SNS topic, and the Slack Lambda notifier. Run it in the **monitoring account**.

```bash
aws cloudformation deploy \
  --template-file cloudformation/monitoring-account.yaml \
  --stack-name "$MONITORING_STACK_NAME" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      OrganizationId="$ORG_ID" \
      SlackWebhookSecretArn="$SLACK_SECRET_ARN" \
      NotificationEmail="$NOTIFICATION_EMAIL" \
  --region "$MONITORING_ACCOUNT_REGION"
```

After deployment, retrieve the OAM sink ARN (you will need it in Step 3):

```bash
SINK_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$MONITORING_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='SinkArn'].OutputValue" \
  --output text \
  --region "$MONITORING_ACCOUNT_REGION")
echo "$SINK_ARN"
```

> **Note:** If you provided a notification email, check your inbox for an SNS subscription confirmation and click **Confirm subscription** before proceeding.

**Expected result:** Stack status is `CREATE_COMPLETE`. The `Central-EC2-Disk-Monitoring` dashboard appears in CloudWatch — it shows no data yet, which is normal.

---

### Step 3 — Deploy to member accounts via StackSets

This step deploys the IAM instance profile, SSM parameter, and OAM link into every account in the target OU. Run from the **management account** (or your delegated StackSets administrator account).

**Validate the template:**

```bash
aws cloudformation validate-template \
  --template-body file://cloudformation/member-account-stackset.yaml \
  --region "$MONITORING_ACCOUNT_REGION"
```

**Create the StackSet:**

```bash
aws cloudformation create-stack-set \
  --stack-set-name "$MEMBER_STACKSET_NAME" \
  --template-body file://cloudformation/member-account-stackset.yaml \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --capabilities CAPABILITY_IAM \
  --parameters \
      ParameterKey=MonitoringSinkIdentifier,ParameterValue="$SINK_ARN" \
      ParameterKey=MonitoringTagValue,ParameterValue=enabled \
  --region "$MONITORING_ACCOUNT_REGION"
```

**Deploy instances to the target OU and region:**

```bash
aws cloudformation create-stack-instances \
  --stack-set-name "$MEMBER_STACKSET_NAME" \
  --deployment-targets OrganizationalUnitIds="$OU_ID" \
  --regions "$MONITORING_ACCOUNT_REGION" \
  --operation-preferences FailureTolerancePercentage=10,MaxConcurrentPercentage=25,RegionConcurrencyType=PARALLEL \
  --region "$MONITORING_ACCOUNT_REGION"
```

> **Note:** Repeat `create-stack-instances` for each additional AWS region you need to cover. SSM parameters, CloudWatch metrics, and OAM links are all regional.

**Check deployment progress:**

```bash
aws cloudformation list-stack-set-operations \
  --stack-set-name "$MEMBER_STACKSET_NAME" \
  --region "$MONITORING_ACCOUNT_REGION"
```

**Expected result:** Operation status is `SUCCEEDED`. Each member account now has an IAM instance profile, an SSM parameter at `/central-monitoring/cloudwatch-agent/linux`, and an active OAM link pointing to the monitoring account.

---

### Step 4 — Enrol an EC2 instance

Do this for each instance you want to monitor.

1. **Attach the instance profile** — the profile name is in the StackSet stack output (`InstanceProfileName`). Add it to the instance's launch template, or attach it to an existing instance using your approved change process.

2. **Verify SSM Agent is installed and running** (on the instance):
   ```bash
   sudo systemctl status amazon-ssm-agent
   ```

3. **Apply the monitoring tag** — replace the instance ID with yours:
   ```bash
   aws ec2 create-tags \
     --resources i-0123456789abcdef0 \
     --tags Key=Monitoring,Value=enabled \
     --region "$MONITORING_ACCOUNT_REGION"
   ```

4. **Wait for State Manager** — within the next association interval (default: 30 minutes), SSM State Manager automatically installs the CloudWatch Agent and applies the configuration.

> **Tip:** To trigger the associations immediately instead of waiting, open **Systems Manager → State Manager** in the AWS Console, select each association, and choose **Apply association now**.

**Expected result:** Within a few minutes of the associations running, `amazon-cloudwatch-agent` is active and `CWAgent/disk_used_percent` metrics start appearing in CloudWatch.

---

## Verification

### Member account checks

**SSM managed node registration:**
```bash
aws ssm describe-instance-information \
  --filters "Key=tag:Monitoring,Values=enabled" \
  --query "InstanceInformationList[*].{ID:InstanceId,Ping:PingStatus,Agent:AgentVersion}" \
  --output table \
  --region "$MONITORING_ACCOUNT_REGION"
```

**State Manager association status:**
```bash
aws ssm list-associations \
  --association-filter-list "key=AssociationName,value=${MEMBER_STACKSET_NAME}-install-cloudwatch-agent" \
  --query "Associations[*].{Name:AssociationName,Status:Overview.Status,LastRun:LastExecutionDate}" \
  --output table \
  --region "$MONITORING_ACCOUNT_REGION"
```

**CloudWatch Agent metrics flowing:**
```bash
aws cloudwatch list-metrics \
  --namespace CWAgent \
  --metric-name disk_used_percent \
  --region "$MONITORING_ACCOUNT_REGION"
```

**On an enrolled Linux instance:**
```bash
sudo systemctl status amazon-cloudwatch-agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status
```

### Monitoring account checks

1. Open the **`Central-EC2-Disk-Monitoring`** dashboard. Member account series should appear in the grouped time-series widget.
2. Confirm the two fleet alarms (`*-fleet-disk-warning`, `*-fleet-disk-critical`) transition from `INSUFFICIENT_DATA` to `OK` once metrics arrive (allow 5–10 minutes).
3. **Test Slack notifications end-to-end** by publishing a test message to the SNS topic:

```bash
TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$MONITORING_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='AlertTopicArn'].OutputValue" \
  --output text \
  --region "$MONITORING_ACCOUNT_REGION")

aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --message '{"AlarmName":"NotificationPathTest","NewStateValue":"ALARM","NewStateReason":"Controlled SNS-to-Slack test"}' \
  --region "$MONITORING_ACCOUNT_REGION"
```

A formatted Slack message should appear within a few seconds. This validates SNS, Lambda, Secrets Manager, and Slack without touching any instance.

---

## Troubleshooting

| Symptom | Likely cause | What to check |
|---|---|---|
| Instance not in SSM managed nodes | SSM Agent not installed or no network path to SSM endpoints | `systemctl status amazon-ssm-agent`; check VPC endpoints or NAT/internet gateway |
| State Manager association failing | IAM permissions missing or agent not running | Review association execution history in SSM console; confirm `amazon-ssm-agent` is active |
| No `CWAgent` metrics in CloudWatch | CloudWatch Agent not configured or not running | `amazon-cloudwatch-agent-ctl -a status`; verify the SSM parameter exists at `/central-monitoring/cloudwatch-agent/linux` |
| No data in central dashboard | OAM link not active | Verify `MonitoringLink` exists in the member stack; check OAM linked sources in the monitoring account's CloudWatch settings |
| Slack messages not arriving | Lambda error or wrong secret | Check Lambda logs at `/aws/lambda/<stack-name>-slack-notifier`; verify the secret ARN and `webhook_url` key in the secret |
| Alarms stuck in `INSUFFICIENT_DATA` | Metrics not yet flowing centrally | Wait 5–10 minutes after first metrics appear; confirm `disk_used_percent` is visible in the member account first |

---

## Operator runbook

### Onboarding a new instance

1. Confirm the account is in the targeted OU and the StackSet instance shows `CURRENT` status.
2. Attach the monitoring IAM instance profile via the launch template or directly to the instance.
3. Tag the instance `Monitoring=enabled`.
4. Verify the instance appears in SSM managed nodes and State Manager compliance is `Compliant`.
5. Confirm `CWAgent/disk_used_percent` metrics appear in the member account, then in the central dashboard.

### Warning alarm response (80%)

1. Open the dashboard and identify the source account, instance ID, and filesystem path above 80%.
2. Connect via Session Manager and run `df -hT` to confirm usage and identify what is growing.
3. Determine whether growth is expected (logs, backups, application data).
4. Open or update an operational ticket with evidence and assign an owner.
5. Apply the approved remediation: log rotation, cleanup, filesystem or EBS expansion, or application fix.
6. Confirm the metric drops below the threshold and the alarm returns to `OK`.

### Critical alarm response (90%)

Follow the warning procedure with incident-level priority appropriate to the service. Do not delete data without application-owner approval. For EBS expansion: resize the volume first, wait for the modification to complete, then extend the partition and filesystem.

### Offboarding an instance

1. Remove or change the `Monitoring` tag on the instance.
2. Confirm State Manager no longer targets the instance.
3. Retain or remove the CloudWatch Agent according to your decommission standard.
4. Remove the instance profile only if no other required permissions depend on it.

---

## Ansible (legacy hosts)

Use Ansible only for hosts that cannot run SSM Agent or as an on-demand audit tool. It does not replace continuous CloudWatch metric collection.

**Install collection requirements:**

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

**Configure the inventory** — edit `inventory.aws_ec2.yml` and replace the placeholder region with your region. Set AWS credentials using your approved identity mechanism.

**Verify the dynamic inventory resolves correctly:**

```bash
ansible-inventory --graph
```

**Bootstrap SSM Agent on legacy hosts:**

```bash
ansible-playbook install-ssm-agent.yml \
  -e aws_region=us-east-1 \
  --limit legacy_linux
```

**Run a read-only disk audit:**

```bash
ansible-playbook disk-audit.yml \
  --limit monitored_linux \
  -e disk_threshold=80
```

**Fail the playbook when any host exceeds the threshold** (useful in CI or automated checks):

```bash
ansible-playbook disk-audit.yml \
  --limit monitored_linux \
  -e disk_threshold=80 \
  -e fail_on_threshold=true
```

---

## Removal

1. Delete all StackSet stack instances (member accounts and regions):
   ```bash
   aws cloudformation delete-stack-instances \
     --stack-set-name "$MEMBER_STACKSET_NAME" \
     --deployment-targets OrganizationalUnitIds="$OU_ID" \
     --regions "$MONITORING_ACCOUNT_REGION" \
     --no-retain-stacks \
     --region "$MONITORING_ACCOUNT_REGION"
   ```
2. Once all instances are removed, delete the StackSet:
   ```bash
   aws cloudformation delete-stack-set \
     --stack-set-name "$MEMBER_STACKSET_NAME" \
     --region "$MONITORING_ACCOUNT_REGION"
   ```
3. Delete the monitoring account stack:
   ```bash
   aws cloudformation delete-stack \
     --stack-name "$MONITORING_STACK_NAME" \
     --region "$MONITORING_ACCOUNT_REGION"
   ```
4. Delete the Slack secret only after confirming no other workload uses it.

---

## Security notes

- **IAM policies are scoped:** `cloudwatch:PutMetricData` on the instance role is restricted to the `CWAgent` namespace; `ssm:GetParameter` is restricted to the agent config parameter path only.
- Restrict the monitoring stack deployment role and StackSet administration roles to only the permissions they need.
- Use VPC interface endpoints where instances have no internet or NAT path: `ssm`, `ssmmessages`, `ec2messages`, and `monitoring` endpoints for the relevant region.
- Keep Slack webhook URLs and SSH private keys out of source control.
- Enable CloudTrail and review StackSet drift and State Manager compliance regularly.
- The Lambda sends account ID, region, alarm name, state, and CloudWatch reason to Slack. Review the channel's data classification before deployment.

---

## Design boundaries

- **Linux only.** Windows instances require a separate agent configuration and alarm strategy (`LogicalDisk` counter).
- **Fleet-level alarms.** The warning and critical alarms evaluate the fleet maximum — they fire when *any* filesystem across all enrolled instances exceeds the threshold. The alarm message does not identify the specific filesystem; use the dashboard to investigate.
- **OAM shares metrics only.** It does not install agents, attach profiles, or create alarms in member accounts.
- **Ansible is supplementary.** State Manager is the continuous metric delivery mechanism. Ansible is for legacy bootstrap and on-demand audits only.

---

## Repository layout

```text
cloudformation/
  member-account-stackset.yaml   Member IAM, SSM configuration and associations, OAM link
  monitoring-account.yaml        OAM sink/policy, dashboard, alarms, SNS, Lambda
cloudwatch/
  agent-config.json              Readable copy of the CloudWatch Agent config embedded in the template
  dashboard.json                 Reference template for dashboard widgets (see _comment field for manual use)
ansible/
  ansible.cfg
  inventory.aws_ec2.yml          Dynamic EC2 inventory
  requirements.yml
  install-ssm-agent.yml          Legacy Linux SSM Agent bootstrap
  disk-audit.yml                 On-demand disk audit playbook
lambda/
  slack-notification.py          Full source matching the inline Lambda in monitoring-account.yaml
diagrams/
  README.md                      Diagram export guidance
```

---

## Known production extensions

- Per-filesystem alarm automation with lifecycle cleanup.
- Windows `LogicalDisk` configuration.
- PagerDuty or incident-management integration replacing or supplementing Slack.
- Dead-letter queue and retry controls for Lambda Slack delivery failures.
- Automated canary metric and notification-path health checks.
- CI pipeline with `cfn-lint`, `yamllint`, `ansible-lint`, and Lambda unit tests.
