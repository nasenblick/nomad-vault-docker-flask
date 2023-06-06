#!/bin/bash

set -e

exec > >(sudo tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# Prepare instance
sudo apt update
sudo apt install unzip

# Install jq
echo "Starting jq install"
sudo snap install jq

# Install consul-template
echo "Starting Consul-Template Installation"
curl -L https://releases.hashicorp.com/consul-template/0.32.0/consul-template_0.32.0_linux_amd64.zip > consul-template.zip
sudo unzip consul-template.zip -d /usr/local/bin
sudo chmod 0755 /usr/local/bin/consul-template
sudo chown root:root /usr/local/bin/consul-template
echo "Concluded Consul-Template Installation"

# Install Vault
echo "Starting Vault Installation"
curl -L https://releases.hashicorp.com/vault/1.13.2/vault_1.13.2_linux_amd64.zip > vault.zip
sudo unzip vault.zip -d /usr/local/bin
sudo chmod 0755 /usr/local/bin/vault
sudo chown root:root /usr/local/bin/vault
echo "Concluded Vault Installation"

# Setup Vault Service
echo "Starting Vault Service Setup"
sudo touch /etc/systemd/system/vault.service

cat <<EOF | sudo tee /etc/systemd/system/vault.service
[Unit]
Description=Vault service
After=network.target
ConditionFileNotEmpty=/etc/vault/config.hcl

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server --config=/etc/vault/config.hcl
ExecReload=/bin/kill --signal=HUP $MAINPID
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
SecureBits=keep-caps
NoNewPrivileges=yes
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF
echo "Concluded Vault Service Setup"

# Configure Vault Server
echo "Starting Vault Server Configuration"
cat <<EOF | sudo tee /etc/vault/config.hcl
storage "file" {
  path = "/etc/vault/data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = "true"
}

api_addr = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"
ui = true
EOF

sudo chown root:root /etc/vault/config.hcl
sudo chmod 640 /etc/vault/config.hcl
sudo mkdir /etc/vault/data
sudo chown root:root /etc/vault/data
sudo chmod 640 /etc/vault/data
echo "Concluded Vault Server Configuration"

# Start Vault Server
echo "Starting Vault Server"
sudo systemctl enable vault
sudo systemctl start vault

VAULT_ADDR=http://127.0.0.1:8200
export VAULT_ADDR

# Initialize Vault and retrieve the initial root token
VAULT_ADDR=http://127.0.0.1:8200
export VAULT_ADDR
sudo vault operator init -key-shares=1 -key-threshold=1 > /tmp/vault_init_output
export VAULT_TOKEN=$(grep "Initial Root Token:" /tmp/vault_init_output | awk '{print $NF}')
echo "Concluded Vault Initialization"

# Store the root token securely (you can modify this as per your requirements)
echo "VAULT_ROOT_TOKEN=${VAULT_TOKEN}" | sudo tee /etc/vault/root_token

# Clean up temporary files
rm /tmp/vault_init_output
echo "Concluded Vault Configuration"
