#!/bin/bash
# =============================================================================
# Ansible Controller – EC2 User Data
# Target OS : Amazon Linux 2023 (x86_64 / aarch64)
# Purpose   : Bootstrap an Ansible controller for the AWS cross-account
#             EC2 disk monitoring solution.
#
# Ansible artifacts:
#   ansible.cfg
#   inventory.aws_ec2.yml
#   agent-status.yml
#   disk-audit.yml
#
# Architecture:
#   Ansible Controller
#       |
#       +-- AssumeRole --> Member Account AnsibleEC2AuditRole
#                              |
#                              +-- SSM SendCommand --> Target EC2
#
# NOTE:
#   Ansible does NOT use the amazon.aws.aws_ssm connection plugin.
#   Ansible does NOT require an S3 bucket.
#   Ansible does NOT use an interactive Session Manager connection.
# =============================================================================

set -euo pipefail

LOG=/var/log/userdata-setup.log

exec > >(tee -a "$LOG") 2>&1

echo "======================================================================"
echo " Ansible controller setup started: $(date)"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. System update and base packages
# ------------------------------------------------------------------------------
echo "--- [1/7] Updating system and installing base packages ---"

dnf update -y

dnf install -y \
  python3.11 \
  python3.11-pip \
  git \
  unzip \
  jq \
  rsync \
  openssh-clients

# Make Python 3.11 the default python3 / pip3
update-alternatives --install \
  /usr/bin/python3 python3 /usr/bin/python3.11 2

update-alternatives --install \
  /usr/bin/pip3 pip3 /usr/bin/pip3.11 2

# ------------------------------------------------------------------------------
# 2. Install AWS CLI v2
# ------------------------------------------------------------------------------
echo "--- [2/7] Installing AWS CLI v2 ---"

if ! command -v aws >/dev/null 2>&1; then

  ARCH="$(uname -m)"

  case "$ARCH" in
    x86_64)
      AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
      ;;
    aarch64)
      AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
      ;;
    *)
      echo "Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac

  TMP_DIR="$(mktemp -d)"

  curl -fsSL "$AWS_CLI_URL" \
    -o "$TMP_DIR/awscliv2.zip"

  unzip -q "$TMP_DIR/awscliv2.zip" \
    -d "$TMP_DIR"

  "$TMP_DIR/aws/install" \
    --update

  rm -rf "$TMP_DIR"

fi

echo "  AWS CLI version:"
aws --version

# ------------------------------------------------------------------------------
# 3. Install Session Manager Plugin
# ------------------------------------------------------------------------------
echo "--- [3/7] Installing Session Manager Plugin ---"

if ! command -v session-manager-plugin >/dev/null 2>&1; then

  ARCH="$(uname -m)"

  case "$ARCH" in
    x86_64)
      SSM_PLUGIN_RPM="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm"
      ;;
    aarch64)
      SSM_PLUGIN_RPM="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_arm64/session-manager-plugin.rpm"
      ;;
    *)
      echo "Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac

  TMP_RPM="$(mktemp --suffix=.rpm)"

  curl -fsSL "$SSM_PLUGIN_RPM" \
    -o "$TMP_RPM"

  dnf install -y "$TMP_RPM"

  rm -f "$TMP_RPM"

fi

echo "  Session Manager Plugin:"
session-manager-plugin --version || true

# ------------------------------------------------------------------------------
# 4. Install Ansible Core and AWS SDK
# ------------------------------------------------------------------------------
echo "--- [4/7] Installing Ansible Core and AWS SDK ---"

python3 -m pip install --upgrade \
  pip \
  setuptools \
  wheel

python3 -m pip install \
  "ansible-core>=2.16" \
  "boto3>=1.34" \
  "botocore>=1.34"

# Ensure pip-installed binaries are available system-wide
cat > /etc/profile.d/ansible-path.sh <<'PATHCFG'
export PATH="$PATH:/usr/local/bin"
PATHCFG

chmod +x /etc/profile.d/ansible-path.sh

export PATH="$PATH:/usr/local/bin"

echo "  Ansible:"
ansible --version | head -1

echo "  Python:"
python3 --version

# ------------------------------------------------------------------------------
# 5. Create Ansible controller user
# ------------------------------------------------------------------------------
echo "--- [5/7] Creating ansible user ---"

if ! id ansible >/dev/null 2>&1; then
  useradd \
    -m \
    -s /bin/bash \
    -c "Ansible controller" \
    ansible
fi

# PATH for login shells
cat > /home/ansible/.bashrc_ansible <<'EOF'
export PATH="$PATH:/usr/local/bin"
EOF

cat /home/ansible/.bashrc_ansible >> /home/ansible/.bashrc

chown ansible:ansible /home/ansible/.bashrc_ansible
chown ansible:ansible /home/ansible/.bashrc

# ------------------------------------------------------------------------------
# 6. Install amazon.aws collection
# ------------------------------------------------------------------------------
echo "--- [6/7] Installing amazon.aws Ansible collection ---"

su - ansible -c \
  "/usr/local/bin/ansible-galaxy collection install amazon.aws"

echo "  Installed amazon.aws collection:"
su - ansible -c \
  "/usr/local/bin/ansible-galaxy collection list amazon.aws"

# ------------------------------------------------------------------------------
# 7. Create project directory and next steps
# ------------------------------------------------------------------------------
echo "--- [7/7] Creating project directory ---"

PROJECT_DIR=/opt/disk-monitoring

mkdir -p "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/ansible"

chown -R ansible:ansible "$PROJECT_DIR"

cat > "$PROJECT_DIR/NEXT_STEPS.txt" <<STEPS
=======================================================================
 Ansible Controller — Ready
 Setup log       : $LOG
 Setup completed : $(date)
=======================================================================

ARCHITECTURE
------------
This controller runs the Ansible AWS dynamic inventory and operational
audit playbooks.

Ansible uses:

  Monitoring Account EC2 Role
          |
          +-- sts:AssumeRole
                    |
                    v
          Member Account AnsibleEC2AuditRole
                    |
                    +-- SSM SendCommand
                              |
                              v
                         Target EC2

The Ansible solution does NOT use:

  - amazon.aws.aws_ssm connection plugin
  - S3 bucket
  - S3 object transfer
  - Interactive Session Manager for Ansible


IAM REQUIREMENTS
----------------
The EC2 instance profile attached to this controller must provide:

  ec2:DescribeInstances
  ec2:DescribeTags

and:

  sts:AssumeRole

to:

  arn:aws:iam::<MEMBER-ACCOUNT-ID>:role/AnsibleEC2AuditRole


MEMBER ACCOUNT ROLE
-------------------
The member account must contain:

  AnsibleEC2AuditRole

Its trust relationship must allow the monitoring-account controller
role to assume it.

The role must allow SSM SendCommand against instances tagged:

  Monitoring=enabled


STEP 1 — Switch to ansible user
--------------------------------
  sudo su - ansible


STEP 2 — Go to the project
----------------------------
  cd $PROJECT_DIR/ansible


STEP 3 — Copy the project files
--------------------------------
Copy the following files into:

  $PROJECT_DIR/

  monitoring-account.yaml
  member-account-stackset.yaml

And into:

  $PROJECT_DIR/ansible/

  ansible.cfg
  inventory.aws_ec2.yml
  agent-status.yml
  disk-audit.yml


STEP 4 — Verify AWS identity
-----------------------------
  aws sts get-caller-identity --no-cli-pager

The normal identity should be the monitoring-account EC2 controller
role.


STEP 5 — Verify Ansible inventory
----------------------------------
  cd $PROJECT_DIR/ansible

  ansible-inventory --graph

Only running EC2 instances tagged:

  Monitoring=enabled

should appear in the monitored group.


STEP 6 — Run agent status audit
--------------------------------
  ansible-playbook agent-status.yml


STEP 7 — Run disk audit
------------------------
  ansible-playbook disk-audit.yml


EXPECTED RESULT
---------------
Agent status should show:

  SSM Agent      : running
  CloudWatch     : active

Disk audit should report filesystem utilization and identify any
filesystem at or above the configured 80 percent threshold.


USEFUL CHECKS
-------------
  ansible --version
  python3 --version
  aws --version
  session-manager-plugin --version
  ansible-galaxy collection list amazon.aws
  ansible-inventory --graph

Setup log:

  $LOG
STEPS

chown ansible:ansible "$PROJECT_DIR/NEXT_STEPS.txt"

echo ""
echo "======================================================================"
echo " Ansible controller setup complete: $(date)"
echo ""
echo " AWS CLI:"
aws --version

echo ""
echo " Ansible:"
ansible --version | head -1

echo ""
echo " Python:"
python3 --version

echo ""
echo " Session Manager Plugin:"
session-manager-plugin --version || true

echo ""
echo " Next steps:"
echo "   cat $PROJECT_DIR/NEXT_STEPS.txt"

echo ""
echo " Full setup log:"
echo "   $LOG"

echo "======================================================================"