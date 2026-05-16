#!/usr/bin/env bash
# =============================================================================
# setup-keycloak.sh — runs via cloud-init (always root, Ubuntu 22.04)
# =============================================================================
set -Eeuo pipefail
trap 'echo "[ERROR] line ${LINENO} exited with $?" >&2' ERR

KEYCLOAK_DIR="/opt/keycloak"
SCRIPT_URL="https://raw.githubusercontent.com/juba-touam/start-up-scritps/main"
COMPOSE_FILE="$KEYCLOAK_DIR/docker-compose.keycloak.yaml"
KC_BASE_URL="https://127.0.0.1:8443"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-adminpass}"
MAX_WAIT="${MAX_WAIT:-300}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "[$(date -u +%H:%M:%S)] ✗ $*" >&2; exit 1; }

# =============================================================================
# 1 — Docker
# =============================================================================
log "[1/6] Installing Docker..."

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin jq openssl \
  || die "Docker install failed"

systemctl enable --now docker

# Wait for Docker daemon to be ready instead of fixed sleep
log "Waiting for Docker daemon..."
timeout 30 bash -c 'until docker info &>/dev/null; do sleep 1; done' \
  || die "Docker daemon did not start in time"

# =============================================================================
# 2 — Directory
# =============================================================================
log "[2/6] Preparing $KEYCLOAK_DIR..."
mkdir -p "$KEYCLOAK_DIR"

# =============================================================================
# 3 — Compose file
# =============================================================================
log "[3/6] Downloading docker-compose..."
tmp=$(mktemp)
for attempt in 1 2 3 4 5; do
  if curl -fsSL --max-time 30 "$SCRIPT_URL/docker-compose.keycloak.yaml" -o "$tmp"; then
    [[ -s "$tmp" ]] || die "Downloaded compose file is empty"
    mv "$tmp" "$COMPOSE_FILE"
    log "✓ compose downloaded (attempt $attempt)"
    break
  fi
  [[ $attempt -lt 5 ]] && { log "retrying ($attempt/5)..."; sleep 3; } || die "Failed to download compose file"
done

# =============================================================================
# 4 — TLS cert
# =============================================================================
log "[4/6] Generating TLS cert..."
cd "$KEYCLOAK_DIR"

cnf=$(mktemp --suffix=.cnf)
cat > "$cnf" <<'EOF'
[req]
distinguished_name = req_dn
x509_extensions    = v3_req
prompt             = no
[req_dn]
CN = keycloak.internal
[v3_req]
subjectAltName   = @alt_names
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
[alt_names]
IP.1  = 127.0.0.1
DNS.1 = keycloak.internal
EOF

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -config "$cnf" -sha256 2>/dev/null \
  || { rm -f "$cnf"; die "openssl failed"; }

rm -f "$cnf"

# 0644 so the Keycloak container (non-root uid 1000) can read both files
chmod 0644 tls.crt tls.key

# =============================================================================
# 5 — Start containers
# =============================================================================
log "[5/6] Starting containers..."
docker compose -f "$COMPOSE_FILE" pull --quiet 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

# =============================================================================
# 6 — Wait for Keycloak
# =============================================================================
log "[6/6] Waiting for Keycloak (max ${MAX_WAIT}s)..."
start=$(date +%s)
until curl -sk --max-time 5 "$KC_BASE_URL/realms/master" -o /dev/null; do
  elapsed=$(( $(date +%s) - start ))
  (( elapsed >= MAX_WAIT )) && {
    docker compose -f "$COMPOSE_FILE" logs --tail 200 keycloak >&2 || true
    die "Keycloak did not start within ${MAX_WAIT}s"
  }
  sleep 3
done
log "✓ Keycloak is up"

# =============================================================================
# Realm + user bootstrap
# =============================================================================
log "Bootstrapping realm..."

token=$(curl -sk --max-time 10 -X POST \
  "$KC_BASE_URL/realms/master/protocol/openid-connect/token" \
  -d "username=$KC_ADMIN_USER" \
  -d "password=$KC_ADMIN_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  | jq -r '.access_token // empty')

[[ -n "$token" ]] || {
  docker compose -f "$COMPOSE_FILE" logs --tail 200 keycloak >&2 || true
  die "Could not get admin token — check KC_ADMIN_USER / KC_ADMIN_PASS"
}

auth=(-sk --max-time 10 -H "Authorization: Bearer $token")

# Realm
realm_status=$(curl "${auth[@]}" -o /dev/null -w "%{http_code}" "$KC_BASE_URL/admin/realms/user")
if [[ "$realm_status" == "200" ]]; then
  log "✓ realm 'user' already exists"
else
  curl "${auth[@]}" -X POST "$KC_BASE_URL/admin/realms" \
    -H "Content-Type: application/json" \
    -d '{"realm":"user","enabled":true}' -o /dev/null \
    && log "✓ realm 'user' created" || die "Failed to create realm"
fi

# User
existing=$(curl "${auth[@]}" \
  "$KC_BASE_URL/admin/realms/user/users?username=platform-admin&exact=true" \
  | jq 'length')

if [[ "$existing" -gt 0 ]]; then
  log "✓ user 'platform-admin' already exists"
else
  uid=$(curl "${auth[@]}" -X POST "$KC_BASE_URL/admin/realms/user/users" \
    -H "Content-Type: application/json" \
    -d '{"username":"platform-admin","enabled":true}' \
    -D - -o /dev/null \
    | grep -i '^Location:' | awk -F'/' '{print $NF}' | tr -d '\r')

  [[ -n "$uid" ]] || die "Could not get new user ID"

  curl "${auth[@]}" -X PUT "$KC_BASE_URL/admin/realms/user/users/$uid/reset-password" \
    -H "Content-Type: application/json" \
    -d '{"type":"password","value":"changeme","temporary":false}' -o /dev/null \
    && log "✓ user 'platform-admin' created" || die "Failed to set user password"
fi
log "=== Setup complete: $KC_BASE_URL ==="