#!/bin/bash

set -e
exec > >(sudo tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1


ACL_DIRECTORY="/ops/shared/config"
NOMAD_BOOTSTRAP_TOKEN="/tmp/nomad_bootstrap"
NOMAD_USER_TOKEN="/tmp/nomad_user_token"
CONFIGDIR="/ops/shared/config"
NOMADVERSION=${nomad_version}
NOMADDOWNLOAD=https://releases.hashicorp.com/nomad/${NOMADVERSION}/nomad_${NOMADVERSION}_linux_amd64.zip
NOMADCONFIGDIR="/etc/nomad.d"
NOMADDIR="/opt/nomad"
HOME_DIR="ubuntu"
CLOUD_ENV=${cloud_env}
VAULT_IP=${vault_private_ip}

# Install phase begin ---------------------------------------

# Install dependencies
case $CLOUD_ENV in
  aws)
    echo "CLOUD_ENV: aws"
    sudo apt-get update && sudo apt-get install -y software-properties-common
    IP_ADDRESS=$(curl http://instance-data/latest/meta-data/local-ipv4)
    PUBLIC_IP=$(curl http://instance-data/latest/meta-data/public-ipv4)
    ;;

  gce)
    echo "CLOUD_ENV: gce"
    sudo apt-get update && sudo apt-get install -y software-properties-common
    IP_ADDRESS=$(curl -H "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/instance/network-interfaces/0/ip)
    ;;

  azure)
    echo "CLOUD_ENV: azure"
    sudo apt-get update && sudo apt-get install -y software-properties-common jq
    IP_ADDRESS=$(curl -s -H Metadata:true --noproxy "*" http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0?api-version=2021-12-13 | jq -r '.["privateIpAddress"]')
    ;;

  *)
    exit "CLOUD_ENV not set to one of aws, gce, or azure - exiting."
    ;;
esac


# Install Dependencies
sudo apt-get install -y unzip tree redis-tools jq curl tmux
sudo apt-get clean
echo "Dependencies installed"


# Disable the firewall
sudo ufw disable || echo "ufw not installed"
echo "Firewall disabled"


# Download and install Nomad
curl -L $NOMADDOWNLOAD > nomad.zip
sudo unzip nomad.zip -d /usr/local/bin
sudo chmod 0755 /usr/local/bin/nomad
sudo chown root:root /usr/local/bin/nomad

sudo mkdir -p $NOMADCONFIGDIR
sudo chmod 755 $NOMADCONFIGDIR
sudo mkdir -p $NOMADDIR
sudo mkdir $NOMADDIR/templates
sudo mkdir $NOMADDIR/cli-certs
sudo mkdir $NOMADDIR/agent-certs
sudo chmod -R 755 $NOMADDIR
sudo chown -R root:root $NOMADDIR

echo "Nomad downloaded and installed"


# Docker
distro=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
sudo apt-get install -y apt-transport-https ca-certificates gnupg2 
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/$${distro} $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce
echo "Docker Installed"


# Java
sudo add-apt-repository -y ppa:openjdk-r/ppa
sudo apt-get update 
sudo apt-get install -y openjdk-8-jdk
JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:bin/java::")
echo "Java Installed"


# CNI plugins
curl -L -o cni-plugins.tgz "https://github.com/containernetworking/plugins/releases/download/v1.0.0/cni-plugins-linux-$( [ $(uname -m) = aarch64 ] && echo arm64 || echo amd64)"-v1.0.0.tgz
sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins.tgz

echo 1 | sudo tee /proc/sys/net/bridge/bridge-nf-call-arptables
echo 1 | sudo tee /proc/sys/net/bridge/bridge-nf-call-ip6tables
echo 1 | sudo tee /proc/sys/net/bridge/bridge-nf-call-iptables
echo "Plugins Installed"

RETRY_JOIN="${retry_join}"
DOCKER_BRIDGE_IP_ADDRESS=(`ifconfig docker0 2>/dev/null|awk '/inet addr:/ {print $2}'|sed 's/addr://'`)

sed -i "s/IP_ADDRESS/$IP_ADDRESS/g" $CONFIGDIR/nomad_client.hcl
sed -i "s/RETRY_JOIN/$RETRY_JOIN/g" $CONFIGDIR/nomad_client.hcl
sudo cp $CONFIGDIR/nomad_client.hcl $NOMADCONFIGDIR/nomad.hcl
sudo cp $CONFIGDIR/nomad.service /etc/systemd/system/nomad.service

echo "Nomad configured"

sudo systemctl enable nomad.service
sudo systemctl start nomad.service

# Wait for Nomad to start
for i in {1..9}; do
    # capture stdout and stderr
    sleep 1
    OUTPUT=$(nomad -v 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error occurred: $OUTPUT"
        continue
    else
        echo "Nomad Started"
        break
    fi
done


# Install consul-template
echo "Starting Consul-Template Installation"
sudo curl -L https://releases.hashicorp.com/consul-template/0.32.0/consul-template_0.32.0_linux_amd64.zip > consul-template.zip
sudo unzip consul-template.zip -d /usr/local/bin
sudo chmod 0755 /usr/local/bin/consul-template
sudo chown root:root /usr/local/bin/consul-template

sudo mkdir -p /etc/consul-template.d
sed -i "s|VAULT_IP|$VAULT_IP|g" $CONFIGDIR/consul-template.hcl
sudo cp $CONFIGDIR/consul-template.hcl /etc/consul-template.d/consul-template.hcl
sudo cp $CONFIGDIR/consul-template.service /etc/systemd/system/consul-template.service
sudo cp $CONFIGDIR/templates/NomadClients/* /opt/nomad/templates
sudo chmod -R 644 /opt/nomad/templates

sudo systemctl enable consul-template.service
sudo systemctl start consul-template.service

echo "Consule-Template Started"


## Install Waypoint 0.11.0 (binary)
sudo curl -L https://releases.hashicorp.com/waypoint/0.11.0/waypoint_0.11.0_linux_amd64.zip > waypoint.zip
sudo unzip waypoint.zip -d /usr/local/bin
sudo cp $CONFIGDIR/waypoint.service /etc/systemd/system/waypoint.service
sudo mkdir -p /nomad/host-volumes/wp-server
sudo mkdir -p /nomad/host-volumes/wp-runner
sudo systemctl enable waypoint
sudo systemctl start waypoint

echo "Waypoint started"


## Install Pack
sudo add-apt-repository ppa:cncf-buildpacks/pack-cli
sudo apt-get install pack-cli

echo "Pack installed"


# Add hostname to /etc/hosts
echo "127.0.0.1 $(hostname)" | sudo tee --append /etc/hosts

echo "Hostname added"


# Add Docker bridge network IP to /etc/resolv.conf (at the top)
echo "nameserver $DOCKER_BRIDGE_IP_ADDRESS" | sudo tee /etc/resolv.conf.new
cat /etc/resolv.conf | sudo tee --append /etc/resolv.conf.new
sudo mv /etc/resolv.conf.new /etc/resolv.conf

echo "Docker bridge network ip added"


# Set env vars
echo "export NOMAD_ADDR=http://$IP_ADDRESS:4646" | sudo tee --append /home/$HOME_DIR/.bashrc
echo "export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64/jre"  | sudo tee --append /home/$HOME_DIR/.bashrc


# Server setup phase finish -----------------------------------
echo "Server setup finished"
