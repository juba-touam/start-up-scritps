#!/bin/bash
set -euo pipefail

echo "=== Keycloak Setup Start ==="

KEYCLOAK_DIR="/opt/keycloak"
SCRIPT_URL="https://raw.githubusercontent.com/juba-touam/start-up-scritps/main/"

# 1. Install Docker
echo "[1/4] Installing Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc
cat /tmp/docker.asc | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# 2. Setup directories
echo "[2/4] Creating Keycloak directories..."
mkdir -p "$KEYCLOAK_DIR"

# 3. Download docker-compose.yml from GitHub
echo "[3/4] Downloading docker-compose.yml..."
curl -fsSL "$SCRIPT_URL/docker-compose.keycloak.yaml" -o "$KEYCLOAK_DIR/docker-compose.yml"

# 4. Generate self-signed SSL certificates
echo "[4/4] Generating SSL certificates..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -subj "/CN=keycloak.internal" \
  -keyout "$KEYCLOAK_DIR/key.pem" \
  -out "$KEYCLOAK_DIR/cert.pem"

# 5. Start containers
echo "Starting Docker containers..."
cd "$KEYCLOAK_DIR"
docker compose up -d

# Wait for Keycloak ready
echo "Waiting for Keycloak to be ready (max 120 seconds)..."
for i in {1..120}; do
  if curl -sf -k https://127.0.0.1:8443/ > /dev/null 2>&1; then
    echo "✓ Keycloak is ready!"
    break
  fi
  echo "Waiting... ($i/120)"
  sleep 1
done

# Create realm "user"
echo "Creating realm 'user'..."
TOKEN=$(curl -s -X POST "https://127.0.0.1:8443/realms/master/protocol/openid-connect/token" \
  -k \
  -d "username=admin&password=adminpass&grant_type=password&client_id=admin-cli" | jq -r '.access_token')

if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
  curl -s -k -X POST "https://127.0.0.1:8443/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "realm": "user",
      "enabled": true,
      "users": [
        {
          "username": "platform-admin",
          "enabled": true,
          "credentials": [
            {
              "type": "password",
              "value": "changeme",
              "temporary": false
            }
          ]
        }
      ]
    }' && echo "✓ Realm 'user' created!" || echo "⚠ Realm creation failed"
else
  echo "⚠ Failed to obtain admin token"
fi

echo "=== Keycloak Setup Complete ==="
echo "✓ Keycloak running at https://127.0.0.1:8443 (internal only)"