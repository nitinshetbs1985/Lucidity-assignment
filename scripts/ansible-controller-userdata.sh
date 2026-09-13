#!/bin/bash
# =============================================================================
# Ansible Controller – EC2 User Data
# Target OS : Amazon Linux 2023 (x86_64 or aarch64)
# Purpose   : Bootstrap a host that can run the disk-monitoring-solution
#             Ansible playbooks (disk-audit.yml, install-ssm-agent.yml)
#             against EC2 targets via SSH and dynamic EC2 inventory.
#
# After launch:
#   1. Attach an IAM instance profile that includes ec2:DescribeInstances
#      and ec2:DescribeTags (needed by the aws_ec2 inventory plugin).
#   2. Copy the project to /opt/disk-monitoring (see NEXT_STEPS.txt).
#   3. sudo su - ansible  →  cd /opt/disk-monitoring/ansible
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

# Make python3.11 / pip3.11 the default python3 / pip3 for new shells
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 2
update-alternatives --install /usr/bin/pip3    pip3    /usr/bin/pip3.11    2

# ------------------------------------------------------------------------------
# 2. Ansible Core and AWS SDK
# ------------------------------------------------------------------------------
echo "--- [2/7] Installing ansible-core, boto3, botocore ---"

# Upgrade pip itself first to avoid bdist_wheel errors
python3 -m pip install --upgrade pip setuptools wheel

# ansible-core 2.16+ requires Python >= 3.10 on the controller (satisfied by 3.11)
# boto3/botocore are required by the amazon.aws.aws_ec2 dynamic inventory plugin
python3 -m pip install \
  "ansible-core>=2.16" \
  "boto3>=1.34" \
  "botocore>=1.34"

# Ensure pip-installed binaries (ansible, ansible-galaxy, etc.) are on PATH
# for all users and login shells
echo 'export PATH=$PATH:/usr/local/bin' > /etc/profile.d/ansible-path.sh
chmod +x /etc/profile.d/ansible-path.sh
export PATH=$PATH:/usr/local/bin

echo "  ansible-core version: $(ansible --version | head -1)"

# ------------------------------------------------------------------------------
# 3. Ansible controller user
# ------------------------------------------------------------------------------
echo "--- [3/7] Creating ansible user ---"

id ansible &>/dev/null || useradd -m -s /bin/bash -c "Ansible controller" ansible

# Password-less sudo — needed for become:true in install-ssm-agent.yml
echo "ansible ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ansible
chmod 440 /etc/sudoers.d/ansible

# Make sure PATH is also set for the ansible user's non-interactive shells
echo 'export PATH=$PATH:/usr/local/bin' >> /home/ansible/.bashrc
chown ansible:ansible /home/ansible/.bashrc

# ------------------------------------------------------------------------------
# 4. SSH key for connecting to legacy Linux target hosts
# ------------------------------------------------------------------------------
echo "--- [4/7] Generating SSH key pair for Ansible connections ---"

SSH_DIR=/home/ansible/.ssh
mkdir -p "$SSH_DIR"

ssh-keygen -t ed25519 \
  -f "$SSH_DIR/id_ansible" \
  -N "" \
  -C "ansible-controller-$(hostname -s)"

# SSH client config:
#   StrictHostKeyChecking accept-new  — trusts on first connect, rejects changed
#   keys. This honours the project's host_key_checking = True setting in
#   ansible.cfg without requiring manual known_hosts population.
cat > "$SSH_DIR/config" <<'SSHCFG'
Host *
    StrictHostKeyChecking accept-new
    IdentityFile          ~/.ssh/id_ansible
    ConnectTimeout        10
    ServerAliveInterval   60
    ServerAliveCountMax   3
SSHCFG

chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/id_ansible"
chmod 644 "$SSH_DIR/id_ansible.pub"
chmod 600 "$SSH_DIR/config"
chown -R ansible:ansible "$SSH_DIR"

echo "  Public key (add to ~/.ssh/authorized_keys on each legacy target host):"
cat "$SSH_DIR/id_ansible.pub"

# ------------------------------------------------------------------------------
# 5. Install amazon.aws Ansible collection
# ------------------------------------------------------------------------------
echo "--- [5/7] Installing amazon.aws collection for the ansible user ---"

# Run as ansible so the collection lands in ~/.ansible/collections — the path
# Ansible resolves relative to the running user, matching the project's
# default ansible.cfg (no custom collections_paths set).
su - ansible -c "/usr/local/bin/ansible-galaxy collection install amazon.aws" \
  2>&1 | tee -a "$LOG"

echo "  Installed collections:"
su - ansible -c "/usr/local/bin/ansible-galaxy collection list amazon.aws"

# ------------------------------------------------------------------------------
# 6. Project directory
# ------------------------------------------------------------------------------
echo "--- [6/7] Creating project directory ---"

PROJECT_DIR=/opt/disk-monitoring
mkdir -p "$PROJECT_DIR"
chown ansible:ansible "$PROJECT_DIR"

# ------------------------------------------------------------------------------
# 7. Next-steps guidance file
# ------------------------------------------------------------------------------
echo "--- [7/7] Writing NEXT_STEPS.txt ---"

PUBLIC_KEY=$(cat "$SSH_DIR/id_ansible.pub")

cat > "$PROJECT_DIR/NEXT_STEPS.txt" <<STEPS
=======================================================================
 Ansible Controller — Ready
 Setup log: $LOG
 Setup completed: $(date)
=======================================================================

BEFORE YOU START
----------------
Attach an IAM instance profile to this EC2 instance that includes at
minimum:

  ec2:DescribeInstances
  ec2:DescribeTags

These permissions are required by the amazon.aws.aws_ec2 dynamic
inventory plugin used in inventory.aws_ec2.yml.


STEP 1 — Copy the project to this machine
------------------------------------------
From your workstation (where you downloaded disk-monitoring-solution):

  rsync -avz --exclude='.git' \\
    ./disk-monitoring-solution/ \\
    ansible@$(hostname -f):$PROJECT_DIR/

Or use SCP:

  scp -r ./disk-monitoring-solution/* \\
    ansible@$(hostname -f):$PROJECT_DIR/


STEP 2 — Switch to the ansible user
-------------------------------------
  sudo su - ansible


STEP 3 — Configure the inventory region
-----------------------------------------
  cd $PROJECT_DIR/ansible
  vi inventory.aws_ec2.yml

  Replace:
    - <type your region example eu-central-1>
  With your actual region, e.g.:
    - us-east-1


STEP 4 — Install the collection from requirements.yml
-------------------------------------------------------
  cd $PROJECT_DIR/ansible
  ansible-galaxy collection install -r requirements.yml


STEP 5 — Verify the dynamic inventory
---------------------------------------
  ansible-inventory --graph

  You should see groups: monitored_linux, legacy_linux, and env_* groups
  based on the Environment tag of your running EC2 instances.


STEP 6 — Run the disk audit (read-only)
-----------------------------------------
  ansible-playbook disk-audit.yml \\
    --limit monitored_linux \\
    -e disk_threshold=80


STEP 7 — Bootstrap SSM Agent on legacy hosts (if needed)
----------------------------------------------------------
  ansible-playbook install-ssm-agent.yml \\
    -e aws_region=us-east-1 \\
    --limit legacy_linux


LEGACY HOST SSH ACCESS
-----------------------
Add the public key below to ~/.ssh/authorized_keys on each legacy target
host. The key was generated during this controller setup.

  $PUBLIC_KEY


TROUBLESHOOTING
---------------
  ansible --version                              Check Ansible is installed
  python3 --version                              Should be 3.11.x
  ansible-galaxy collection list amazon.aws      Verify collection installed
  cat $LOG                   Full setup log
STEPS

chown ansible:ansible "$PROJECT_DIR/NEXT_STEPS.txt"

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------
echo ""
echo "======================================================================"
echo " Setup complete: $(date)"
echo " Public key (add to legacy target hosts):"
cat "$SSH_DIR/id_ansible.pub"
echo ""
echo " Next steps: cat $PROJECT_DIR/NEXT_STEPS.txt"
echo " Full log  : $LOG"
echo "======================================================================"
