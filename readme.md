# AWS Cross-Account EC2 Disk Monitoring

## Overview

Minimal cross-account EC2 disk monitoring using:

- AWS Systems Manager (SSM)
- CloudWatch Agent
- CloudWatch custom metrics
- CloudWatch Observability Access Manager (OAM)
- CloudWatch Dashboard and Alarm
- Ansible for agent and disk audits

Region: `eu-central-1`

```text
Member Account
EC2 → SSM → CloudWatch Agent → CWAgent/disk_used_percent
                                      │
                                   OAM Link
                                      │
                                      ▼
Monitoring Account
OAM Sink → Dashboard / Alarm
```

Ansible is used separately for operational checks:

```text
Ansible EC2
    │
    └─ AssumeRole → AnsibleEC2AuditRole
                         │
                         └─ SSM Run Command → Target EC2
```

No Slack, SNS, Lambda, Secrets Manager, Ansible S3 or interactive SSM connection is required.

---

# 1. Repository

```text
project/
├── monitoring-account.yaml
├── member-account-stackset.yaml
└── ansible/
    ├── ansible.cfg
    ├── inventory.aws_ec2.yml
    ├── agent-status.yml
    └── disk-audit.yml
```

---

# 2. Prerequisites

Two AWS accounts are required:

```text
Monitoring Account: <MONITORING-ACCOUNT-ID>
Member Account:     <MEMBER-ACCOUNT-ID>
Region:             eu-central-1
```

Required AWS CLI profiles:

```text
<MONITORING-AWS-PROFILE>
<MEMBER-AWS-PROFILE>
```

Verify access:

```powershell
aws sts get-caller-identity --profile <MONITORING-AWS-PROFILE> --no-cli-pager

aws sts get-caller-identity --profile <MEMBER-AWS-PROFILE> --no-cli-pager
```

---

# 3. Deploy Monitoring Account

Deploy `monitoring-account.yaml`:

```powershell
aws cloudformation deploy `
  --profile <MONITORING-AWS-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-monitoring-sink `
  --template-file .\monitoring-account.yaml `
  --capabilities CAPABILITY_NAMED_IAM `
  --parameter-overrides `
    MemberAccountId=<MEMBER-ACCOUNT-ID> `
  --no-cli-pager
```

Retrieve the OAM Sink ARN:

```powershell
aws cloudformation describe-stacks `
  --profile <MONITORING-AWS-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-monitoring-sink `
  --query "Stacks[0].Outputs[?OutputKey=='SinkArn'].OutputValue" `
  --output text `
  --no-cli-pager
```

Save the returned ARN for the member-account deployment.

---

# 4. Deploy Member Account

Deploy `member-account-stackset.yaml`:

```powershell
aws cloudformation deploy `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-member-monitoring `
  --template-file .\member-account-stackset.yaml `
  --capabilities CAPABILITY_NAMED_IAM `
  --parameter-overrides `
    MonitoringSinkIdentifier="<OAM-SINK-ARN>" `
  --no-cli-pager
```

The stack configures:

- EC2 monitoring IAM role and instance profile
- CloudWatch Agent SSM parameter
- CloudWatch Agent installation association
- CloudWatch Agent configuration association
- OAM Link

---

# 5. Prepare the EC2 Instance

Target instances must be running and tagged:

```text
Monitoring=enabled
```

Add the tag if required:

```powershell
aws ec2 create-tags `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --resources <INSTANCE-ID> `
  --tags Key=Monitoring,Value=enabled `
  --no-cli-pager
```

Verify:

```powershell
aws ec2 describe-instances `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --filters "Name=tag:Monitoring,Values=enabled" `
  --query "Reservations[].Instances[].[InstanceId,State.Name]" `
  --output table `
  --no-cli-pager
```

---

# 6. Verify SSM and CloudWatch Agent

Check SSM:

```powershell
aws ssm describe-instance-information `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --query "InstanceInformationList[].[InstanceId,PingStatus,AgentVersion]" `
  --output table `
  --no-cli-pager
```

Expected:

```text
PingStatus = Online
```

Check CloudWatch Agent associations:

```powershell
aws ssm list-associations `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --output table `
  --no-cli-pager
```

The agent publishes:

```text
Namespace: CWAgent
Metric:    disk_used_percent
Interval:  5 minutes
```

Verify the source metric:

```powershell
aws cloudwatch list-metrics `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --namespace CWAgent `
  --metric-name disk_used_percent `
  --output table `
  --no-cli-pager
```

---

# 7. Verify Monitoring

In the monitoring account, open:

```text
CloudWatch
  → Dashboards
    → Sandbox-EC2-Disk-Monitoring
```

Verify the disk metric is visible.

Also verify the CloudWatch alarm under:

```text
CloudWatch
  → Alarms
```

The alarm evaluates:

```text
CWAgent / disk_used_percent
```

---

# 8. Ansible Setup

The Ansible controller is an EC2 instance in the monitoring account.

Connect to the controller and run:

```bash
cd /home/ec2-user/fluidity-assignment/ansible
```

Verify:

```bash
ansible --version
aws --version
ansible-galaxy collection list
```

The `amazon.aws` collection is required.

Verify the controller identity:

```bash
aws sts get-caller-identity --no-cli-pager
```

It should use the monitoring-account controller role.

If temporary AWS credentials were previously exported:

```bash
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
```

---

# 9. Ansible Inventory

File:

```text
ansible/inventory.aws_ec2.yml
```

The inventory discovers:

- running EC2 instances
- tagged `Monitoring=enabled`

and uses:

```text
AnsibleEC2AuditRole
```

for member-account access.

Verify:

```bash
ansible-inventory --graph
```

Expected:

```text
@all:
  |--@aws_ec2:
  |  |--i-xxxxxxxxxxxxxxxxx
  |--@monitored:
  |  |--i-xxxxxxxxxxxxxxxxx
```

---

# 10. Agent Status Audit

Run:

```bash
ansible-playbook agent-status.yml
```

The playbook checks:

- SSM Agent
- CloudWatch Agent

For Ubuntu instances using the Snap-based SSM Agent, the audit checks the running process rather than relying only on the traditional systemd service.

---

# 11. Disk Audit

Run:

```bash
ansible-playbook disk-audit.yml
```

The playbook reports filesystem usage and identifies filesystems at or above:

```text
80%
```

Example:

```text
=== DISK USAGE ===

Filesystem     Type   Size  Used Avail Use% Mounted on
/dev/root      ext4   6.8G  4.8G  2.0G  71% /

=== DISKS ABOVE 80 PERCENT ===
```

An empty final section means no filesystem is at or above the threshold.

---

# 12. Final Validation

Run from the Ansible controller:

```bash
cd /home/ec2-user/fluidity-assignment/ansible

ansible-inventory --graph

ansible-playbook agent-status.yml

ansible-playbook disk-audit.yml
```

The MVP is complete when:

```text
EC2
 ↓
SSM
 ↓
CloudWatch Agent
 ↓
CWAgent/disk_used_percent
 ↓
OAM Link
 ↓
OAM Sink
 ↓
Dashboard / Alarm
```

and the Ansible audits successfully report agent status and disk utilization.

---

# 13. Troubleshooting

## CloudFormation ROLLBACK_COMPLETE

Delete the failed stack:

```powershell
aws cloudformation delete-stack `
  --profile <PROFILE> `
  --region eu-central-1 `
  --stack-name <STACK-NAME> `
  --no-cli-pager
```

Then wait:

```powershell
aws cloudformation wait stack-delete-complete `
  --profile <PROFILE> `
  --region eu-central-1 `
  --stack-name <STACK-NAME>
```

Redeploy afterwards.

## Ansible Cannot Find an Instance

Check:

```text
Instance state = running
Monitoring=enabled
```

Then:

```bash
ansible-inventory --graph
```

## Ansible AccessDenied on SSM

The playbook must assume:

```text
AnsibleEC2AuditRole
```

Do not add `ssm:SendCommand` to the monitoring controller role just to resolve this error.

## SSM Agent Appears Inactive

On Snap-based Ubuntu installations:

```bash
pgrep -af amazon-ssm-agent
```

or:

```bash
snap services amazon-ssm-agent
```

may be more accurate than:

```bash
systemctl is-active amazon-ssm-agent
```

---

# 14. MVP Scope

Included:

- Cross-account CloudWatch metric sharing with OAM
- EC2 disk monitoring
- CloudWatch Dashboard
- CloudWatch Alarm
- SSM-based CloudWatch Agent management
- Ansible agent-status audit
- Ansible disk audit

Not included:

```text
Slack
SNS
Email
Lambda
Secrets Manager
Ansible S3
Interactive Session Manager for Ansible
Control Tower delegated administration
AWS Organizations delegated administration
```
