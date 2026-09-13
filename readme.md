# AWS Cross-Account EC2 Disk Monitoring

## Overview

This project provides a minimal cross-account monitoring solution for EC2 disk utilization using:

* AWS Systems Manager (SSM)
* Amazon CloudWatch Agent
* Amazon CloudWatch custom metrics
* CloudWatch Observability Access Manager (OAM)
* CloudWatch Dashboard
* CloudWatch Alarm

The solution separates the **member/source account**, where EC2 instances run, from the **central monitoring account**, where monitoring data is consumed.

Notification integrations such as Slack, SNS, and email are intentionally excluded from this MVP.

---

## Architecture

```text
                    CENTRAL MONITORING ACCOUNT
                    ──────────────────────────

                         AWS OAM Sink
                              │
                              │
                    ┌─────────┴─────────┐
                    │                   │
             CloudWatch Dashboard   CloudWatch Alarm
                    │
                    │
════════════════════╪════════════════════════════════
                    │
                 OAM Link
                    │
                    │ Cross-account
                    │ CloudWatch metrics
                    │
════════════════════╪════════════════════════════════
                    │
                    ▼
                       MEMBER ACCOUNT
                    ──────────────────

                       EC2 Instances
                            │
                            │ SSM
                            ▼
                    CloudWatch Agent
                            │
                            │
                    disk_used_percent
                            │
                            ▼
                       CloudWatch
```

---

# Components

## Monitoring Account

The monitoring account contains:

### OAM Sink

An `AWS::Oam::Sink` receives observability data from the member account.

The sink policy permits the member account to create/update an OAM Link for:

```text
AWS::CloudWatch::Metric
```

### CloudWatch Dashboard

The dashboard provides visibility into EC2 disk utilization metrics.

Dashboard:

```text
Sandbox-EC2-Disk-Monitoring
```

### CloudWatch Alarm

A basic CloudWatch alarm evaluates the EC2 disk utilization metric:

```text
Namespace: CWAgent
Metric:    disk_used_percent
```

---

## Member Account

The member account contains the resources required to collect and share EC2 disk metrics.

### SSM

AWS Systems Manager is used to manage the CloudWatch Agent on targeted EC2 instances.

Instances are targeted using the tag:

```text
Monitoring=enabled
```

### CloudWatch Agent

The CloudWatch Agent collects:

```text
disk_used_percent
```

at a five-minute interval.

Metrics are published to:

```text
Namespace: CWAgent
```

### OAM Link

An `AWS::Oam::Link` connects the member account to the OAM Sink in the monitoring account.

Only CloudWatch metrics are shared by this MVP.

---

# CloudFormation Templates

The project uses two CloudFormation templates.

## 1. Monitoring Account

File:

```text
monitoring-account.yaml
```

Creates:

* OAM Sink
* OAM Sink Policy
* CloudWatch Dashboard
* CloudWatch Alarm

No SNS, Slack, Lambda, or Secrets Manager resources are required.

---

## 2. Member Account

File:

```text
member-account-stackset.yaml
```

Creates/configures:

* CloudWatch Agent configuration in SSM Parameter Store
* SSM association for CloudWatch Agent installation
* SSM association for CloudWatch Agent configuration
* OAM Link
* EC2 monitoring IAM role/instance profile where required

### IAM role consideration

The deployment requires permission to create IAM resources if the template creates the EC2 monitoring role.

If the EC2 instances already have an appropriate IAM role providing:

```text
AmazonSSMManagedInstanceCore
CloudWatchAgentServerPolicy
```

the existing role should preferably be reused rather than creating another IAM role.

---

# Deployment Sequence

The deployment must be performed in the following order.

## Step 1 – Authenticate to AWS

Authenticate to the appropriate AWS accounts using AWS IAM Identity Center / SSO.

Verify the identity before deploying:

```powershell
aws sts get-caller-identity `
  --profile <PROFILE> `
  --no-cli-pager
```

Confirm that the returned account is the intended target account.

---

# Step 2 – Deploy the Monitoring Account Stack

Deploy:

```text
monitoring-account.yaml
```

to the central monitoring account.

Example:

```powershell
aws cloudformation deploy `
  --profile <MONITORING-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-monitoring-sink `
  --template-file .\monitoring-account.yaml `
  --capabilities CAPABILITY_NAMED_IAM `
  --parameter-overrides `
    MemberAccountId=<MEMBER-ACCOUNT-ID> `
  --no-cli-pager
```

The stack creates the OAM Sink and monitoring resources.

---

# Step 3 – Retrieve the OAM Sink ARN

After the monitoring stack has completed successfully, retrieve the Sink ARN:

```powershell
aws cloudformation describe-stacks `
  --profile <MONITORING-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-monitoring-sink `
  --query "Stacks[0].Outputs[?OutputKey=='SinkArn'].OutputValue" `
  --output text `
  --no-cli-pager
```

Example output:

```text
arn:aws:oam:eu-central-1:<MONITORING-ACCOUNT-ID>:sink/<SINK-ID>
```

This ARN is required by the member-account deployment.

---

# Step 4 – Deploy the Member Account Stack

Deploy:

```text
member-account-stackset.yaml
```

to the member account.

Pass the OAM Sink ARN obtained in Step 3.

Example:

```powershell
aws cloudformation deploy `
  --profile <MEMBER-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-member-monitoring `
  --template-file .\member-account-stackset.yaml `
  --capabilities CAPABILITY_NAMED_IAM `
  --parameter-overrides `
    MonitoringSinkIdentifier="<OAM-SINK-ARN>" `
  --no-cli-pager
```

---

# Step 5 – Verify the OAM Link

Retrieve the OAM Link ARN:

```powershell
aws cloudformation describe-stacks `
  --profile <MEMBER-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-member-monitoring `
  --query "Stacks[0].Outputs[?OutputKey=='OamLinkArn'].OutputValue" `
  --output text `
  --no-cli-pager
```

The member account should now have an OAM Link associated with the monitoring account's Sink.

---

# Step 6 – Verify EC2 Instances

The CloudWatch Agent SSM associations target EC2 instances with:

```text
Monitoring=enabled
```

Verify the instances:

```powershell
aws ec2 describe-instances `
  --profile <MEMBER-PROFILE> `
  --region eu-central-1 `
  --filters "Name=tag:Monitoring,Values=enabled" `
  --query "Reservations[].Instances[].[InstanceId,State.Name]" `
  --output table `
  --no-cli-pager
```

---

# Step 7 – Verify SSM

Confirm that the EC2 instances are registered with Systems Manager:

```powershell
aws ssm describe-instance-information `
  --profile <MEMBER-PROFILE> `
  --region eu-central-1 `
  --query "InstanceInformationList[].[InstanceId,PingStatus,AgentVersion]" `
  --output table `
  --no-cli-pager
```

The expected state is:

```text
PingStatus = Online
```

---

# Step 8 – Verify CloudWatch Agent

Verify the SSM associations responsible for:

1. Installing the CloudWatch Agent
2. Configuring the CloudWatch Agent

```powershell
aws ssm list-associations `
  --profile <MEMBER-PROFILE> `
  --region eu-central-1 `
  --output table `
  --no-cli-pager
```

The CloudWatch Agent should be configured to collect:

```text
disk_used_percent
```

every five minutes.

---

# Step 9 – Verify CloudWatch Metrics

From the member account, verify that the metric exists:

```powershell
aws cloudwatch list-metrics `
  --profile <MEMBER-PROFILE> `
  --region eu-central-1 `
  --namespace CWAgent `
  --metric-name disk_used_percent `
  --output table `
  --no-cli-pager
```

The metric should appear after the CloudWatch Agent has started publishing data.

---

# Step 10 – Verify Cross-Account Monitoring

Using the monitoring-account profile, verify that the member-account CloudWatch metrics are available through OAM.

```powershell
aws cloudwatch list-metrics `
  --profile <MONITORING-PROFILE> `
  --region eu-central-1 `
  --namespace CWAgent `
  --metric-name disk_used_percent `
  --output table `
  --no-cli-pager
```

This confirms the intended flow:

```text
Member EC2
    ↓
CloudWatch Agent
    ↓
CWAgent/disk_used_percent
    ↓
OAM Link
    ↓
OAM Sink
    ↓
Monitoring Account
```

---

# Step 11 – Verify Dashboard

Open CloudWatch in the monitoring account and navigate to:

```text
CloudWatch
  → Dashboards
    → Sandbox-EC2-Disk-Monitoring
```

Verify that the EC2 disk utilization data is visible.

---

# Step 12 – Verify Alarm

Verify that the disk utilization alarm exists in the monitoring account.

The MVP alarm evaluates:

```text
Namespace:
CWAgent

Metric:
disk_used_percent
```

The alarm is currently intended as a monitoring/validation mechanism.

Notification delivery is outside the scope of this MVP.

---

# Troubleshooting

## CloudFormation stack is ROLLBACK_COMPLETE

A stack in:

```text
ROLLBACK_COMPLETE
```

cannot be updated.

Delete the failed stack:

```powershell
aws cloudformation delete-stack `
  --profile <PROFILE> `
  --region eu-central-1 `
  --stack-name <STACK-NAME> `
  --no-cli-pager
```

Wait for deletion:

```powershell
aws cloudformation wait stack-delete-complete `
  --profile <PROFILE> `
  --region eu-central-1 `
  --stack-name <STACK-NAME>
```

Then redeploy.

---

## CloudFormation Early Validation Error

For an early validation failure, inspect CloudFormation events:

```powershell
aws cloudformation describe-events `
  --profile <PROFILE> `
  --region eu-central-1 `
  --stack-name <STACK-NAME> `
  --no-cli-pager `
  --output table
```

Do not modify the template based only on the generic:

```text
AWS::EarlyValidation::PropertyValidation
```

Retrieve the detailed validation event first.

---

## IAM CreateRole Permission Error

If deployment fails with:

```text
iam:CreateRole
```

the deployment identity does not have permission to create the IAM role.

Options:

1. Reuse an existing EC2 IAM role with the required SSM and CloudWatch Agent permissions.
2. Request the required IAM permissions for the deployment role.
3. Remove IAM role creation from the CloudFormation template and manage the EC2 role separately.

For a minimal sandbox implementation, option 1 or 3 is preferred where possible.

---

# Design Principles

The MVP intentionally follows these principles:

### 1. No centralized delegated administrator

The solution does not require:

* AWS Organizations delegated administration
* Control Tower delegated administration
* A separate central management account
* StackSets from an organization management account

The OAM Sink is created directly in the monitoring account.

---

### 2. Minimal cross-account access

The OAM Sink policy allows the designated member account to create/update the OAM Link and share:

```text
AWS::CloudWatch::Metric
```

No broader observability resource types are required for the MVP.

---

### 3. SSM-based agent management

SSM is used to install and configure the CloudWatch Agent on EC2 instances tagged:

```text
Monitoring=enabled
```

This avoids manually installing/configuring the agent on each instance.

---

### 4. No notification infrastructure

The MVP deliberately excludes:

```text
SNS
Slack
Lambda
Secrets Manager
Email
```

These can be added later without changing the core OAM architecture.

---

# Future Enhancements

Once the basic monitoring path is proven, the solution can be extended with:

* SNS notifications
* Slack integration
* Email notifications
* More precise disk alarms
* Per-instance dashboards
* Additional EC2 metrics
* CPU and memory monitoring
* Filesystem-specific alarms
* Auto Scaling dimensions
* Additional OAM resource types
* Infrastructure deployment through CI/CD

These enhancements should be added only after the core:

```text
EC2 → CloudWatch Agent → OAM Link → OAM Sink → Dashboard
```

flow is confirmed to work.

---

# Current MVP Scope

```text
┌──────────────────────────────────────────────┐
│              MEMBER ACCOUNT                  │
│                                              │
│  EC2                                         │
│   │                                          │
│   ├── SSM                                    │
│   │                                          │
│   └── CloudWatch Agent                       │
│            │                                 │
│            └── disk_used_percent             │
│                      │                       │
│                  OAM Link                    │
└──────────────────────┼───────────────────────┘
                       │
                       │ CloudWatch Metrics
                       ▼
┌──────────────────────────────────────────────┐
│           MONITORING ACCOUNT                 │
│                                              │
│               OAM Sink                       │
│                  │                           │
│          ┌───────┴────────┐                  │
│          ▼                ▼                  │
│      Dashboard          Alarm                 │
│                                              │
└──────────────────────────────────────────────┘
```

The objective of this MVP is to prove **secure cross-account EC2 disk monitoring using CloudWatch OAM**, while keeping the infrastructure and operational dependencies to a minimum.
