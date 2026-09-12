# Centralized EC2 Disk Utilization Monitoring

A deployable reference implementation for centralized Linux disk monitoring across AWS accounts. Member accounts use Systems Manager State Manager to install and configure the CloudWatch Agent. CloudWatch cross-account observability shares metrics with a monitoring account. The monitoring account provides a dashboard, fleet-level warning and critical alarms, SNS notifications, and a Lambda-based Slack notifier.

## Important design boundaries

- The solution collects Linux `disk_used_percent` metrics. Windows needs a separate agent configuration and alarm strategy.
- CloudWatch does not create disk-space dashboards or 80%/90% alarms automatically. This repository creates them.
- OAM shares telemetry but does not install agents, attach IAM instance profiles, or create alarms.
- Creating an instance profile does not attach it to existing EC2 instances. Reference the profile in a launch template or attach it as a controlled onboarding action.
- The supplied 80% and 90% alarms evaluate the fleet maximum. They provide a scalable central signal, but the alarm message does not reliably identify the exact filesystem. The dashboard query groups by source account, instance, and path for investigation. Production environments that require per-filesystem alarm identity should add controlled alarm lifecycle automation.
- Ansible is an exception path for legacy SSM bootstrap and on-demand audits. It is not the continuous metric collector.

## Repository layout

```text
cloudformation/
  member-account-stackset.yaml  Member IAM, SSM configuration and associations, OAM link
  monitoring-account.yaml       OAM sink/policy, dashboard, alarms, SNS, Lambda
cloudwatch/
  agent-config.json             Readable source of the embedded agent configuration
  dashboard.json                Readable source/reference for dashboard widgets
ansible/
  ansible.cfg
  inventory.aws_ec2.yml         Example dynamic inventory
  requirements.yml
  install-ssm-agent.yml         Legacy Linux bootstrap
  disk-audit.yml                On-demand disk audit
lambda/
  slack-notification.py         Full source corresponding to the inline Lambda
 diagrams/
  README.md                     Diagram export guidance
```

## Prerequisites

1. An AWS Organization and a dedicated monitoring account.
2. CloudFormation StackSets trusted access if service-managed StackSets are used.
3. Target EC2 instances must have network access to Systems Manager and CloudWatch endpoints through internet/NAT or VPC interface endpoints.
4. EC2 instances must use an IAM instance profile with `AmazonSSMManagedInstanceCore` and `CloudWatchAgentServerPolicy`, or equivalent least-privilege policies.
5. An existing AWS Secrets Manager secret holding a Slack incoming-webhook URL. Store either the plain URL or JSON such as `{"webhook_url":"https://hooks.slack.com/..."}`. Do not commit the URL.
6. AWS CLI v2 and credentials with deployment permissions.
7. For Ansible: Python 3, Ansible Core, the `amazon.aws` collection, and network/SSH access to legacy hosts.

## Deployment order

### 1. Create the Slack secret

Example only. The shell history can expose values, so use an approved secret-entry workflow in production.

```bash
aws secretsmanager create-secret \
  --name central-monitoring/slack-webhook \
  --secret-string file://slack-secret.json \
  --region us-east-1
```

Example local `slack-secret.json` that must not be committed:

```json
{"webhook_url":"https://hooks.slack.com/services/REPLACE/ME"}
```

### 2. Deploy the monitoring-account stack

```bash
aws cloudformation deploy \
  --template-file cloudformation/monitoring-account.yaml \
  --stack-name central-disk-monitoring \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      OrganizationId=o-example12345 \
      SlackWebhookSecretArn=arn:aws:secretsmanager:us-east-1:111122223333:secret:central-monitoring/slack-webhook-xxxxxx \
      NotificationEmail=operations@example.com \
  --region us-east-1
```

Obtain the OAM sink ARN:

```bash
SINK_ARN=$(aws cloudformation describe-stacks \
  --stack-name central-disk-monitoring \
  --query "Stacks[0].Outputs[?OutputKey=='SinkArn'].OutputValue" \
  --output text \
  --region us-east-1)
echo "$SINK_ARN"
```

If an email endpoint was supplied, confirm the SNS subscription from the mailbox.

### 3. Deploy the member template with StackSets

Validate first:

```bash
aws cloudformation validate-template \
  --template-body file://cloudformation/member-account-stackset.yaml \
  --region us-east-1
```

Create a service-managed StackSet:

```bash
aws cloudformation create-stack-set \
  --stack-set-name central-disk-monitoring-member \
  --template-body file://cloudformation/member-account-stackset.yaml \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --capabilities CAPABILITY_IAM \
  --parameters \
      ParameterKey=MonitoringSinkIdentifier,ParameterValue="$SINK_ARN" \
      ParameterKey=MonitoringTagValue,ParameterValue=enabled \
  --region us-east-1
```

Create instances for a target organizational unit and Region:

```bash
aws cloudformation create-stack-instances \
  --stack-set-name central-disk-monitoring-member \
  --deployment-targets OrganizationalUnitIds=ou-xxxx-yyyyyyyy \
  --regions us-east-1 \
  --operation-preferences FailureTolerancePercentage=10,MaxConcurrentPercentage=25,RegionConcurrencyType=PARALLEL \
  --region us-east-1
```

Repeat stack instances for every required Region because SSM parameters, associations, CloudWatch metrics, and OAM links are regional.

### 4. Enrol an EC2 instance

1. Attach the generated instance profile through the instance's launch template, or attach it to an existing instance using your approved change process.
2. Ensure SSM Agent is installed and running.
3. Apply the tag `Monitoring=enabled`.
4. Ensure outbound HTTPS access to regional SSM, SSM Messages, EC2 Messages where applicable, CloudWatch, and S3/package endpoints.
5. State Manager installs the `AmazonCloudWatchAgent` Distributor package and configures it from `/central-monitoring/cloudwatch-agent/linux`.

Example tag command:

```bash
aws ec2 create-tags \
  --resources i-0123456789abcdef0 \
  --tags Key=Monitoring,Value=enabled \
  --region us-east-1
```

## Verification

### Member account

```bash
aws ssm describe-instance-information \
  --filters Key=tag:Monitoring,Values=enabled \
  --region us-east-1

aws ssm list-associations \
  --association-filter-list key=AssociationName,value=central-disk-monitoring-member-install-cloudwatch-agent \
  --region us-east-1

aws cloudwatch list-metrics \
  --namespace CWAgent \
  --metric-name disk_used_percent \
  --region us-east-1
```

On an enrolled Linux instance:

```bash
sudo systemctl status amazon-ssm-agent
sudo systemctl status amazon-cloudwatch-agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status
```

### Monitoring account

1. Open the `Central-EC2-Disk-Monitoring` dashboard.
2. Confirm linked-account series appear in the grouped Metrics Insights widget.
3. Confirm the two fleet alarms are not in `INSUFFICIENT_DATA` after metrics have arrived.
4. Test notification plumbing without filling a disk by publishing a temporary message to the SNS topic. This validates SNS, Lambda, Secrets Manager, and Slack, but not the CloudWatch alarm itself.

```bash
TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name central-disk-monitoring \
  --query "Stacks[0].Outputs[?OutputKey=='AlertTopicArn'].OutputValue" \
  --output text \
  --region us-east-1)

aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --message '{"AlarmName":"NotificationPathTest","NewStateValue":"ALARM","NewStateReason":"Controlled SNS-to-Slack test"}' \
  --region us-east-1
```

## Operator runbook

### Normal onboarding

1. Confirm the account is in a targeted OU and the StackSet instance is current.
2. Use the monitoring instance profile in the EC2 launch template.
3. Tag the instance `Monitoring=enabled`.
4. Verify SSM managed-node registration and State Manager compliance.
5. Verify `CWAgent/disk_used_percent` in the member account, then in the central dashboard.

### Warning response at 80%

1. Open the central dashboard and find the source account, instance ID, and path above the threshold.
2. Use Session Manager or the approved access path to run `df -hT` and identify growth.
3. Check expected application/log retention and whether cleanup is authorized.
4. Open or update the operational ticket, record evidence, and assign an owner.
5. Apply the approved remediation: log rotation, cleanup, filesystem expansion, or application correction.
6. Confirm the metric is below threshold and the alarm returns to OK.

### Critical response at 90%

Follow the warning procedure with incident priority appropriate to the service. Avoid deleting data without application-owner approval. If expanding EBS, follow the platform change process and extend the partition/filesystem only after the volume modification succeeds.

### Offboarding

1. Remove or change the `Monitoring` tag.
2. Confirm State Manager no longer targets the instance.
3. Retain or remove the agent according to the decommission standard.
4. Remove the instance profile only if no other required permissions depend on it.

## Ansible operator path

Install requirements:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

Update `inventory.aws_ec2.yml` with the required Regions and configure AWS credentials through the approved identity mechanism. Test inventory:

```bash
ansible-inventory --graph
```

Bootstrap SSM Agent only on a controlled legacy group:

```bash
ansible-playbook install-ssm-agent.yml \
  -e aws_region=us-east-1 \
  --limit legacy_linux
```

Run a read-only audit:

```bash
ansible-playbook disk-audit.yml \
  --limit monitored_linux \
  -e disk_threshold=80
```

To make the audit fail for CI or an operational wrapper when any path breaches the threshold:

```bash
ansible-playbook disk-audit.yml \
  --limit monitored_linux \
  -e disk_threshold=80 \
  -e fail_on_threshold=true
```

## Files required on the operator machine

- This repository.
- AWS CLI configuration or an approved federated credential helper.
- Ansible configuration, dynamic inventory, playbooks, and collections for legacy operations.
- SSH private key only when unavoidable for a legacy host, protected outside Git.
- No Slack webhook file after the secret is created. The webhook remains in Secrets Manager.

## Security notes

- Replace AWS managed policies with scoped customer-managed policies if organizational standards require it.
- Restrict the monitoring stack deployment role and StackSet administration roles.
- Use VPC endpoints where instances have no internet/NAT path.
- Keep Slack URLs and private keys out of source control.
- Enable CloudTrail and review StackSet drift and State Manager compliance.
- The Lambda sends account, Region, alarm name, state, and CloudWatch reason. Review the Slack channel's data classification before use.

## Removal

1. Delete StackSet instances from member accounts and Regions.
2. Delete the StackSet after instances are removed.
3. Delete the monitoring stack.
4. Delete the Slack secret only after confirming no other workload uses it.

## Known production extensions

- Per-filesystem alarm automation with lifecycle cleanup.
- Windows `LogicalDisk` configuration.
- PagerDuty or incident-management integration.
- Dead-letter queue and retry controls for Slack delivery.
- Automated canary metric and notification-path health checks.
- CI checks using `cfn-lint`, `yamllint`, `ansible-lint`, and Python unit tests.
