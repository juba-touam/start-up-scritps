#!/bin/bash
set -euo pipefail

KEYCLOAK_DIR="/opt/keycloak"
SCRIPT_URL="https://raw.githubusercontent.com/juba-touam/start-up-scritps/main"
COMPOSE_FILE="$KEYCLOAK_DIR/docker-compose.keycloak.yaml"
MAX_WAIT=300

echo "=== Keycloak one-shot setup ==="

# require root
if [ "$(id -u)" -ne 0 ]; then
  echo "✗ must run as root"
  exit 1
fi

# Install prerequisites and Docker (idempotent)
echo "[1/6] Installing prerequisites and Docker..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release jq openssl || true
install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc
gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.asc 2>/dev/null || cat /tmp/docker.asc | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || { echo "✗ docker install failed"; exit 1; }
systemctl enable --now docker

# Create directory
echo "[2/6] Preparing directory $KEYCLOAK_DIR ..."
mkdir -p "$KEYCLOAK_DIR"
chown root:root "$KEYCLOAK_DIR"
chmod 0755 "$KEYCLOAK_DIR"

# Download compose file with retries
echo "[3/6] Downloading docker-compose..."
attempts=0
rm -f "$COMPOSE_FILE"
while [ $attempts -lt 5 ]; do
  attempts=$((attempts+1))
  if curl -fsSL "$SCRIPT_URL/docker-compose.keycloak.yaml" -o "$COMPOSE_FILE"; then
    echo "✓ downloaded compose (attempt $attempts)"
    break
  fi
  echo "retrying compose download ($attempts/5)..."
  sleep 2
done
if [ ! -s "$COMPOSE_FILE" ]; then
  echo "✗ failed to download compose file"
  exit 1
fi

# Generate TLS certs where many Keycloak compose files expect them
echo "[4/6] Generating TLS certs (tls.crt, tls.key)..."
cd "$KEYCLOAK_DIR"
# create cert valid for CN=keycloak.internal and IP 127.0.0.1
cat > openssl.cnf <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = keycloak.internal

[v3_req]
subjectAltName = @alt_names

[alt_names]
IP.1 = 127.0.0.1
DNS.1 = keycloak.internal
EOF

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -config openssl.cnf -sha256 >/dev/null 2>&1 || { echo "✗ openssl failed"; exit 1; }
chmod 0644 tls.crt
chmod 0600 tls.key
rm -f openssl.cnf

# Start containers
echo "[5/6] Starting containers..."
cd "$KEYCLOAK_DIR"
docker compose -f "$COMPOSE_FILE" pull --ignore-pull-failures || true
docker compose -f "$COMPOSE_FILE" up -d

# Wait for Keycloak readiness (realms/master endpoint)
echo "[6/6] Waiting for Keycloak (max ${MAX_WAIT}s)..."
start_ts=$(date +%s)
ready=0
while :; do
  if curl -s -k --max-time 5 https://127.0.0.1:8443/realms/master >/dev/null 2>&1; then
    ready=1
    echo "✓ Keycloak HTTP endpoint responded"
    break
  fi
  now=$(date +%s)
  elapsed=$((now-start_ts))
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "✗ timeout waiting for Keycloak (showing last 200 lines of logs)"
    docker compose -f "$COMPOSE_FILE" logs --tail 200 keycloak || docker logs --tail 200 $(docker ps -a --filter "name=keycloak" --format '{{.ID}}' | head -n1) || true
    exit 1
  fi
  sleep 2
done

# Create realm 'user' if not exists
echo "Creating realm 'user'..."
set +e
TOKEN=$(curl -s -X POST "https://127.0.0.1:8443/realms/master/protocol/openid-connect/token" -k \
  -d "username=admin&password=adminpass&grant_type=password&client_id=admin-cli" | jq -r '.access_token' 2>/dev/null)
set -e

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "✗ could not obtain admin token; check admin credentials or Keycloak logs"
  docker compose -f "$COMPOSE_FILE" logs --tail 200 keycloak || true
  exit 1
fi

# create realm if not exists
EXISTS=$(curl -s -k -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:8443/admin/realms/user" -o /dev/null -w "%{http_code}")
if [ "$EXISTS" = "200" ]; then
  echo "✓ realm 'user' already exists"
else
  curl -s -k -X POST "https://127.0.0.1:8443/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "realm":"user",
      "enabled":true,
      "users":[
        {"username":"platform-admin","enabled":true,"credentials":[{"type":"password","value":"changeme","temporary":false}]}
      ]
    }' && echo "✓ realm 'user' created" || { echo "✗ failed to create realm"; docker compose -f "$COMPOSE_FILE" logs --tail 200 keycloak || true; exit 1; }
fi

echo "=== Keycloak setup complete: https://127.0.0.1:8443 ==="
exit 0