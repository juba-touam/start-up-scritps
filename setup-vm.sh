#!/bin/bash
set -euo pipefail

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc
cat /tmp/docker.asc | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker azureuser

# Récupérer les fichiers depuis GitHub
for FILE in create-service.sh deploy.sh docker-compose.back.yaml docker-compose.front.yaml nginx.conf; do
  curl -sL "https://raw.githubusercontent.com/juba-touam/start-up-scritps/main/$FILE" -o "/home/azureuser/$FILE"
done
chmod +x /home/azureuser/*.sh

# Lancer le script
/home/azureuser/create-service.sh
