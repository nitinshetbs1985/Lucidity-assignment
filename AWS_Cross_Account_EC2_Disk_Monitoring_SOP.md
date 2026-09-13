# Standard Operating Procedure (SOP)
## AWS Cross-Account EC2 Disk Monitoring

### 1. Purpose
This SOP covers deployment, configuration, troubleshooting, and validation of a minimal cross-account EC2 disk monitoring solution using Amazon EC2, AWS Systems Manager (SSM), CloudWatch Agent, Amazon CloudWatch, CloudWatch Observability Access Manager (OAM), a CloudWatch Dashboard, and a CloudWatch Alarm.

Primary metric: `CWAgent / disk_used_percent`

The core implementation excludes SNS, Lambda, Slack, and other notification components.

### 2. Environment

| Item | Value |
|---|---|
| AWS Region | `eu-central-1` |
| Monitoring Account | `<MONITORING-ACCOUNT-ID>` |
| Monitoring CLI Profile | `<MONITORING-AWS-PROFILE>` |
| Member/Source Account | `<MEMBER-ACCOUNT-ID>` |
| Member CLI Profile | `<MEMBER-AWS-PROFILE>` |
| EC2 Instance | `<INSTANCE-ID>` |
| Monitoring Tag | `Monitoring=enabled` |
| OAM Sink ARN | `arn:aws:oam:eu-central-1:<MONITORING-ACCOUNT-ID>:sink/<SINK-ID>` |
| OAM Link ARN | `arn:aws:oam:eu-central-1:<MEMBER-ACCOUNT-ID>:link/<LINK-ID>` |

Do not place real AWS account IDs, instance IDs, Sink IDs, Link IDs, hostnames, credentials, tokens, webhook URLs, or other sensitive environment-specific identifiers in copies intended for external sharing.

### 3. Architecture

```text
MEMBER / SOURCE ACCOUNT
EC2 (Monitoring=enabled)
        |
        v
    SSM Agent
        |
        v
CloudWatch Agent
        |
        v
CWAgent/disk_used_percent
        |
        v
CloudWatch Metrics
        |
        v
     OAM Link
        |
        v
     OAM Sink
        |
        v
MONITORING ACCOUNT
CloudWatch Observability
        |
   +----+----+
   |         |
Dashboard   Alarm
```

### 4. Prerequisites

Verify monitoring-account access:

```powershell
aws sts get-caller-identity `
  --profile <MONITORING-AWS-PROFILE> `
  --no-cli-pager
```

Verify member-account access:

```powershell
aws sts get-caller-identity `
  --profile <MEMBER-AWS-PROFILE> `
  --no-cli-pager
```

Confirm the profiles have the required deployment permissions.

### 5. Deploy Monitoring Account Stack

The monitoring stack should contain the OAM Sink, Sink policy, CloudWatch Dashboard, and CloudWatch Alarm.

```powershell
aws cloudformation deploy `
  --profile <MONITORING-AWS-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-monitoring-sink `
  --template-file .\monitoring-account.yaml `
  --capabilities CAPABILITY_NAMED_IAM `
  --no-cli-pager
```

Verify:

```powershell
aws cloudformation describe-stacks `
  --profile <MONITORING-AWS-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-monitoring-sink `
  --output table `
  --no-cli-pager
```

Retrieve outputs:

```powershell
aws cloudformation describe-stacks `
  --profile <MONITORING-AWS-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-monitoring-sink `
  --query "Stacks[0].Outputs" `
  --output table `
  --no-cli-pager
```

Record the generated Sink ARN for the member-account deployment.

### 6. Verify OAM Sink

```powershell
aws oam list-sinks `
  --profile <MONITORING-AWS-PROFILE> `
  --region eu-central-1 `
  --output json `
  --no-cli-pager
```

Retrieve the policy:

```powershell
aws oam get-sink-policy `
  --profile <MONITORING-AWS-PROFILE> `
  --region eu-central-1 `
  --sink-identifier "arn:aws:oam:eu-central-1:<MONITORING-ACCOUNT-ID>:sink/<SINK-ID>" `
  --output json `
  --no-cli-pager
```

The policy should allow the member account to perform `oam:CreateLink` and `oam:UpdateLink`, restricted to `AWS::CloudWatch::Metric`.

Example:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowMemberAccount",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<MEMBER-ACCOUNT-ID>:root"
      },
      "Action": [
        "oam:CreateLink",
        "oam:UpdateLink"
      ],
      "Resource": "*",
      "Condition": {
        "ForAllValues:StringEquals": {
          "oam:ResourceTypes": "AWS::CloudWatch::Metric"
        }
      }
    }
  ]
}
```

### 7. Deploy Member Account Stack

The member stack should create the IAM role, EC2 instance profile, CloudWatch Agent SSM parameter, SSM associations, and OAM Link.

```powershell
aws cloudformation deploy `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-member-monitoring `
  --template-file .\member-account-stackset.yaml `
  --capabilities CAPABILITY_NAMED_IAM `
  --parameter-overrides `
    SinkArn="arn:aws:oam:eu-central-1:<MONITORING-ACCOUNT-ID>:sink/<SINK-ID>" `
  --no-cli-pager
```

Verify:

```powershell
aws cloudformation describe-stacks `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --stack-name sandbox-member-monitoring `
  --query "Stacks[0].Outputs" `
  --output table `
  --no-cli-pager
```

### 8. Verify EC2 Monitoring Tag

The target instance must have `Monitoring=enabled`.

```powershell
aws ec2 describe-instances `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --instance-ids <INSTANCE-ID> `
  --query "Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Tags:Tags,Profile:IamInstanceProfile.Arn}" `
  --output json `
  --no-cli-pager
```

Confirm the instance is `running` and has `Monitoring=enabled`.

### 9. Verify EC2 Instance Profile

```powershell
aws ec2 describe-instances `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --instance-ids <INSTANCE-ID> `
  --query "Reservations[0].Instances[0].IamInstanceProfile" `
  --output json `
  --no-cli-pager
```

### 10. Verify SSM Connectivity

```powershell
aws ssm describe-instance-information `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --output table `
  --no-cli-pager
```

Expected:

```text
PingStatus = Online
```

### 11. Verify CloudWatch Agent SSM Parameter

```powershell
aws ssm get-parameter `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --name "/central-monitoring/cloudwatch-agent/linux" `
  --query "Parameter.Value" `
  --output text `
  --no-cli-pager
```

Expected configuration includes:

```json
{
  "agent": {
    "metrics_collection_interval": 300,
    "run_as_user": "root"
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    }
  }
}
```

The disk collector should include:

```json
"measurement": [
  "used_percent"
]
```

### 12. Troubleshooting: Install CloudWatch Agent

If the CloudFormation SSM installation association fails, test installation manually.

Create `install-agent.json`:

```json
{
  "action": ["Install"],
  "installationType": ["Uninstall and reinstall"],
  "name": ["AmazonCloudWatchAgent"],
  "version": ["latest"]
}
```

Send:

```powershell
aws ssm send-command `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --instance-ids <INSTANCE-ID> `
  --document-name "AWS-ConfigureAWSPackage" `
  --parameters file://install-agent.json `
  --query "Command.[CommandId,Status]" `
  --output table `
  --no-cli-pager
```

Check:

```powershell
aws ssm get-command-invocation `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --command-id "<COMMAND-ID>" `
  --instance-id <INSTANCE-ID> `
  --query "[Status,StatusDetails,ResponseCode,StandardOutputContent,StandardErrorContent]" `
  --output text `
  --no-cli-pager
```

Expected:

```text
Success Success 0
```

### 13. Configure CloudWatch Agent

Create `configure-agent.json`:

```json
{
  "action": ["configure"],
  "mode": ["ec2"],
  "optionalConfigurationSource": ["ssm"],
  "optionalConfigurationLocation": ["/central-monitoring/cloudwatch-agent/linux"],
  "optionalRestart": ["yes"]
}
```

Send:

```powershell
aws ssm send-command `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --instance-ids <INSTANCE-ID> `
  --document-name "AmazonCloudWatch-ManageAgent" `
  --parameters file://configure-agent.json `
  --query "Command.[CommandId,Status]" `
  --output table `
  --no-cli-pager
```

Check:

```powershell
aws ssm get-command-invocation `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --command-id "<COMMAND-ID>" `
  --instance-id <INSTANCE-ID> `
  --query "[Status,StatusDetails,ResponseCode,StandardOutputContent,StandardErrorContent]" `
  --output text `
  --no-cli-pager
```

Expected:

```text
Success Success 0
```

### 14. Troubleshoot SSM GetParameter AccessDenied

A failure similar to:

```text
AccessDeniedException:
User ... is not authorized to perform:
ssm:GetParameter
```

means the IAM role executing the SSM document cannot read the CloudWatch Agent parameter.

Identify the role from the error.

Check attached policies:

```powershell
aws iam list-attached-role-policies `
  --profile <MEMBER-AWS-PROFILE> `
  --role-name "<SSM-EXECUTION-ROLE>" `
  --output table `
  --no-cli-pager
```

Check inline policies:

```powershell
aws iam list-role-policies `
  --profile <MEMBER-AWS-PROFILE> `
  --role-name "<SSM-EXECUTION-ROLE>" `
  --output table `
  --no-cli-pager
```

Verify ARN:

```powershell
aws iam get-role `
  --profile <MEMBER-AWS-PROFILE> `
  --role-name "<SSM-EXECUTION-ROLE>" `
  --query "Role.Arn" `
  --output text `
  --no-cli-pager
```

If an approved troubleshooting change is required, use least privilege:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter"
      ],
      "Resource": "arn:aws:ssm:eu-central-1:<MEMBER-ACCOUNT-ID>:parameter/central-monitoring/cloudwatch-agent/linux"
    }
  ]
}
```

Save as `ssm-cloudwatch-agent-parameter-policy.json`.

Apply:

```powershell
aws iam put-role-policy `
  --profile <MEMBER-AWS-PROFILE> `
  --role-name "<SSM-EXECUTION-ROLE>" `
  --policy-name "CloudWatchAgentParameterAccess" `
  --policy-document file://ssm-cloudwatch-agent-parameter-policy.json `
  --no-cli-pager
```

Verify:

```powershell
aws iam get-role-policy `
  --profile <MEMBER-AWS-PROFILE> `
  --role-name "<SSM-EXECUTION-ROLE>" `
  --policy-name "CloudWatchAgentParameterAccess" `
  --output json `
  --no-cli-pager
```

Note: Manual IAM changes are for troubleshooting/proof of concept. The final production design should manage the required permission through approved infrastructure.

### 15. Verify CloudWatch Agent Status

```powershell
aws ssm send-command `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --instance-ids <INSTANCE-ID> `
  --document-name "AWS-RunShellScript" `
  --parameters 'commands=["systemctl status amazon-cloudwatch-agent --no-pager","/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status"]' `
  --query "Command.CommandId" `
  --output text `
  --no-cli-pager
```

Then:

```powershell
aws ssm get-command-invocation `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --command-id "<COMMAND-ID>" `
  --instance-id <INSTANCE-ID> `
  --output text `
  --no-cli-pager
```

Expected:

```text
Active: active (running)
```

and:

```json
{
  "status": "running",
  "configstatus": "configured"
}
```

### 16. Verify Source Metric

The current configuration collects every 300 seconds. Wait at least one collection interval.

```powershell
aws cloudwatch list-metrics `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --namespace CWAgent `
  --metric-name disk_used_percent `
  --output table `
  --no-cli-pager
```

Expected dimensions include:

```text
MetricName = disk_used_percent
Namespace  = CWAgent
InstanceId = <INSTANCE-ID>
path       = /
fstype     = ext4
```

### 17. Verify Actual Metric Datapoints

Set a time window:

```powershell
$Start = (Get-Date).ToUniversalTime().AddMinutes(-15).ToString("yyyy-MM-ddTHH:mm:ssZ")
$End   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```

Query:

```powershell
aws cloudwatch get-metric-statistics `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --namespace CWAgent `
  --metric-name disk_used_percent `
  --dimensions Name=InstanceId,Value=<INSTANCE-ID> Name=path,Value=/ Name=fstype,Value=ext4 `
  --start-time $Start `
  --end-time $End `
  --period 300 `
  --statistics Average `
  --output json `
  --no-cli-pager
```

Expected:

```json
{
  "Label": "disk_used_percent",
  "Datapoints": [
    {
      "Timestamp": "...",
      "Average": 50.98,
      "Unit": "Percent"
    }
  ]
}
```

This confirms actual datapoints are being published.

### 18. Verify OAM Link

```powershell
aws oam list-links `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --output json `
  --no-cli-pager
```

Retrieve a specific Link:

```powershell
aws oam get-link `
  --profile <MEMBER-AWS-PROFILE> `
  --region eu-central-1 `
  --identifier "arn:aws:oam:eu-central-1:<MEMBER-ACCOUNT-ID>:link/<LINK-ID>" `
  --output json `
  --no-cli-pager
```

Expected:

```text
ResourceTypes:
  AWS::CloudWatch::Metric

SinkArn:
  arn:aws:oam:eu-central-1:<MONITORING-ACCOUNT-ID>:sink/<SINK-ID>
```

### 19. Verify OAM Link Is Attached to Sink

```powershell
aws oam list-attached-links `
  --profile <MONITORING-AWS-PROFILE> `
  --region eu-central-1 `
  --sink-identifier "arn:aws:oam:eu-central-1:<MONITORING-ACCOUNT-ID>:sink/<SINK-ID>" `
  --output json `
  --no-cli-pager
```

Expected:

```json
{
  "Items": [
    {
      "Label": "<SOURCE-ACCOUNT-LABEL>",
      "LinkArn": "arn:aws:oam:eu-central-1:<MEMBER-ACCOUNT-ID>:link/<LINK-ID>",
      "ResourceTypes": [
        "AWS::CloudWatch::Metric"
      ]
    }
  ]
}
```

### 20. Monitoring Account Cross-Account Validation

Do not rely solely on `list-metrics` in the monitoring account to determine whether OAM is functioning.

Use CloudWatch cross-account observability in the monitoring account and select the linked source account.

Navigate to:

```text
CWAgent
  -> disk_used_percent
```

Select:

```text
InstanceId = <INSTANCE-ID>
path       = /
fstype     = ext4
```

The graph should show values corresponding to the source-account datapoints.

### 21. Troubleshooting Decision Tree

```text
Is EC2 running?
       |
       +-- NO -> Start/fix EC2
       |
       +-- YES
             |
             v
Is SSM Online?
       |
       +-- NO -> Fix SSM/instance role/network
       |
       +-- YES
             |
             v
Is CloudWatch Agent installed?
       |
       +-- NO -> Run AWS-ConfigureAWSPackage
       |
       +-- YES
             |
             v
Is Agent configured?
       |
       +-- NO -> Check SSM parameter and ssm:GetParameter
       |
       +-- YES
             |
             v
Is Agent running?
       |
       +-- NO -> Check agent logs/configuration
       |
       +-- YES
             |
             v
Does member CloudWatch contain disk_used_percent?
       |
       +-- NO -> Check agent configuration/logs/IAM
       |
       +-- YES
             |
             v
Does OAM Link exist?
       |
       +-- NO -> Fix member OAM configuration
       |
       +-- YES
             |
             v
Is Link attached to Sink?
       |
       +-- NO -> Fix OAM Sink/Link
       |
       +-- YES
             |
             v
Can monitoring account observe linked metric?
       |
       +-- NO -> Investigate cross-account CloudWatch/OAM access
       |
       +-- YES
             |
             v
Dashboard + Alarm validation
```

### 22. Final Validation Checklist

| Validation | Expected |
|---|---|
| AWS CLI profiles | Valid |
| Monitoring account access | Pass |
| Member account access | Pass |
| Monitoring CloudFormation stack | `CREATE_COMPLETE` |
| Member CloudFormation stack | `CREATE_COMPLETE` |
| EC2 running | Pass |
| `Monitoring=enabled` | Pass |
| EC2 instance profile | Attached |
| SSM Agent | Online |
| CloudWatch Agent installed | Pass |
| SSM parameter | Exists |
| `ssm:GetParameter` | Allowed |
| CloudWatch Agent | Running |
| Agent configuration | Configured |
| `CWAgent/disk_used_percent` | Present |
| Actual datapoints | Present |
| OAM Sink | Exists |
| OAM Sink policy | Correct |
| OAM Link | Exists |
| OAM Link resource type | `AWS::CloudWatch::Metric` |
| OAM Link attached to Sink | Pass |
| Monitoring account cross-account visibility | Pass |
| CloudWatch Dashboard | Visible |
| CloudWatch Alarm | Configured |

### 23. Key Troubleshooting Lessons

**Identify the actual SSM execution role.** The role attached to an EC2 instance is not necessarily the identity shown when an SSM document executes. Inspect the principal in the SSM error.

**Validate datapoints, not only metric existence.** `list-metrics` confirms catalog presence; `get-metric-statistics` confirms actual datapoints.

**OAM is an observability mechanism.** It should not be treated as a mechanism that physically copies source metrics into the sink account as locally owned metrics.

**PowerShell JSON handling.** Complex JSON arguments can be problematic with Windows PowerShell and native executables. For SSM documents, prefer `--parameters file://filename.json`.

**AWS CLI pager.** On Windows, use `--no-cli-pager` to avoid unexpected pager behaviour.

**AWS CLI output syntax.** Use `--output text`, not `--output-text`.

### 24. Operational Sequence

1. Verify AWS CLI profiles.
2. Deploy monitoring-account stack.
3. Verify OAM Sink.
4. Retrieve Sink ARN.
5. Deploy member-account stack.
6. Verify EC2 and `Monitoring=enabled`.
7. Verify EC2 instance profile.
8. Verify SSM connectivity.
9. Verify CloudWatch Agent SSM parameter.
10. Verify CloudWatch Agent installation.
11. Verify SSM parameter access.
12. Configure CloudWatch Agent.
13. Verify Agent is running.
14. Verify `disk_used_percent` exists.
15. Verify actual metric datapoints.
16. Verify OAM Link.
17. Verify Link is attached to Sink.
18. Validate cross-account metric visibility.
19. Validate Dashboard.
20. Validate Alarm.

### 25. Security and Sharing Guidelines

Before committing or distributing this SOP:

- Remove real AWS account IDs.
- Remove real EC2 instance IDs.
- Remove real OAM Sink and Link IDs.
- Remove internal hostnames.
- Remove internal profile names if they reveal account ownership.
- Do not include access keys, secret keys, tokens, passwords, webhook URLs, or Secrets Manager values.
- Use placeholders such as `<MONITORING-ACCOUNT-ID>`, `<MEMBER-ACCOUNT-ID>`, `<INSTANCE-ID>`, `<SINK-ID>`, and `<LINK-ID>`.
- Do not commit environment-specific troubleshooting files containing sensitive values.
