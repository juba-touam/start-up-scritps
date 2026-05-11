#!/bin/bash

# 1. Permissions
sudo chmod +x /home/azureuser/deploy.sh

# Plus besoin du sysctl — docker tourne en root, peut binder le port 80 nativement

# 2. Nettoyage Docker
echo "Nettoyage des conteneurs arrêtés..."
sudo docker container prune -f
sudo docker image prune -f
sudo docker compose down -v

# 3. Test du script deploy.sh
echo "Test du script deploy.sh..."
bash /home/azureuser/deploy.sh
if [ $? -ne 0 ]; then
    echo "ERREUR: deploy.sh a échoué. Corrigez-le avant de continuer."
    exit 1
fi

# 4. Création du dossier service — système cette fois, pas utilisateur
sudo mkdir -p /etc/systemd/system/

# 5. Création du service
sudo tee /etc/systemd/system/deploy.service << 'EOF'
[Unit]
Description=DevOps Deployment Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/azureuser
ExecStartPre=/usr/bin/sleep 2
ExecStart=/usr/bin/bash /home/azureuser/deploy.sh
ExecStop=/usr/bin/bash -c 'cd /home/azureuser  && docker compose down'
ExecStopPost=/usr/bin/bash -c 'cd /home/azureuser && docker compose down 2>/dev/null || true'
TimeoutStartSec=300
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal
Environment=PATH=/usr/bin:/usr/local/bin
Environment=HOME=/home/azureuser

[Install]
WantedBy=multi-user.target
EOF

# 6. Rechargement et démarrage — sudo obligatoire, service système
sudo systemctl daemon-reload
sudo systemctl enable deploy.service
sudo systemctl start deploy.service

# 7. Plus besoin de loginctl enable-linger

# 8. Status
sleep 2
sudo systemctl status deploy.service --no-pager -l
