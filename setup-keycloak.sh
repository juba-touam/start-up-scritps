#!/usr/bin/env bash
# =============================================================================
# keycloak-setup.sh — idempotent, one-shot Keycloak bootstrap for VM startup
# Run as root (e.g. via cloud-init or a systemd oneshot unit)
# =============================================================================
set -Eeuo pipefail
trap 'echo "[ERROR] Script failed at line ${LINENO} (exit $?)" >&2' ERR

# ---------------------------------------------------------------------------
# Config — override via env vars if needed
# ---------------------------------------------------------------------------
KEYCLOAK_DIR="${KEYCLOAK_DIR:-/opt/keycloak}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/juba-touam/start-up-scritps/main}"
COMPOSE_FILE="$KEYCLOAK_DIR/docker-compose.keycloak.yaml"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-adminpass}"   # override this in prod via env/secret manager
KC_BASE_URL="https://127.0.0.1:8443"
MAX_WAIT="${MAX_WAIT:-300}"
CURL_OPTS=(-sk --max-time 10 --retry 3 --retry-delay 2)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
ok()   { echo "[$(date -u +%H:%M:%S)] ✓ $*"; }
die()  { echo "[$(date -u +%H:%M:%S)] ✗ $*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Must run as root"
}

# ---------------------------------------------------------------------------
# 1 — Install Docker (idempotent: skip if docker compose already works)
# ---------------------------------------------------------------------------
install_docker() {
  log "[1/6] Checking Docker..."

  if docker compose version &>/dev/null 2>&1; then
    ok "Docker + Compose already installed — skipping"
    return
  fi

  log "Installing prerequisites..."
  # Clean apt state once, then install
  apt-get update -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release jq openssl

  log "Adding Docker apt repo..."
  install -m 0755 -d /etc/apt/keyrings
  # Fetch and dearmor in one clean pipe — avoids double-dearmor bug
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local arch codename
  arch=$(dpkg --print-architecture)
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    || die "Docker install failed"

  systemctl enable --now docker
  # Brief settle time — avoids "cannot connect to daemon" on first run
  sleep 2
  ok "Docker installed"
}

# ---------------------------------------------------------------------------
# 2 — Prepare directory
# ---------------------------------------------------------------------------
prepare_dir() {
  log "[2/6] Preparing $KEYCLOAK_DIR ..."
  mkdir -p "$KEYCLOAK_DIR"
  chmod 0755 "$KEYCLOAK_DIR"
  ok "Directory ready"
}

# ---------------------------------------------------------------------------
# 3 — Download docker-compose file (idempotent: re-download every time
#     so updates to the remote file are picked up on re-runs)
# ---------------------------------------------------------------------------
download_compose() {
  log "[3/6] Downloading docker-compose..."
  local tmp
  tmp=$(mktemp)
  local attempt
  for attempt in 1 2 3 4 5; do
    if curl -fsSL --max-time 30 \
        "$SCRIPT_URL/docker-compose.keycloak.yaml" -o "$tmp"; then
      [[ -s "$tmp" ]] || die "Downloaded compose file is empty"
      mv "$tmp" "$COMPOSE_FILE"
      ok "Compose file downloaded (attempt $attempt)"
      return
    fi
    log "Compose download attempt $attempt/5 failed — retrying in 3s..."
    sleep 3
  done
  rm -f "$tmp"
  die "Failed to download compose file after 5 attempts"
}

# ---------------------------------------------------------------------------
# 4 — Generate self-signed TLS certs (skip if valid cert already exists)
# ---------------------------------------------------------------------------
generate_tls() {
  log "[4/6] Checking TLS certs..."
  local crt="$KEYCLOAK_DIR/tls.crt"
  local key="$KEYCLOAK_DIR/tls.key"

  # Regenerate if cert is missing or expires within 30 days
  if [[ -f "$crt" && -f "$key" ]] \
      && openssl x509 -checkend $((30 * 86400)) -noout -in "$crt" &>/dev/null; then
    ok "TLS cert still valid — skipping generation"
    return
  fi

  log "Generating TLS cert..."
  local cnf
  cnf=$(mktemp --suffix=.cnf)
  # Write openssl config to a temp file so a mid-step failure doesn't leave
  # a stale file behind in the keycloak dir
  cat > "$cnf" <<'OPENSSL_CNF'
[req]
distinguished_name = req_dn
x509_extensions    = v3_req
prompt             = no

[req_dn]
CN = keycloak.internal

[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment

[alt_names]
IP.1  = 127.0.0.1
DNS.1 = keycloak.internal
OPENSSL_CNF

  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$key" -out "$crt" \
    -config "$cnf" -sha256 2>/dev/null \
    || { rm -f "$cnf"; die "openssl cert generation failed"; }

  rm -f "$cnf"
  chmod 0644 "$crt"
  chmod 0600 "$key"
  ok "TLS cert generated"
}

# ---------------------------------------------------------------------------
# 5 — Start containers (idempotent: 'up -d' is a no-op if already running)
# ---------------------------------------------------------------------------
start_containers() {
  log "[5/6] Starting containers..."
  cd "$KEYCLOAK_DIR"

  # Pull quietly; don't fail the whole script on a pull error (offline images
  # or a private registry that needs auth are handled gracefully)
  docker compose -f "$COMPOSE_FILE" pull --quiet 2>/dev/null || \
    log "Warning: image pull had errors — will try with cached images"

  docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
  ok "Containers started"
}

# ---------------------------------------------------------------------------
# 6 — Wait for Keycloak readiness
# ---------------------------------------------------------------------------
wait_for_keycloak() {
  log "[6/6] Waiting for Keycloak (max ${MAX_WAIT}s)..."
  local start elapsed
  start=$(date +%s)

  while :; do
    if curl "${CURL_OPTS[@]}" "$KC_BASE_URL/realms/master" -o /dev/null; then
      ok "Keycloak is up"
      return
    fi
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed >= MAX_WAIT )); then
      log "Timeout — dumping last 200 log lines:"
      docker compose -f "$COMPOSE_FILE" logs --tail 200 keycloak 2>/dev/null || true
      die "Keycloak did not become ready within ${MAX_WAIT}s"
    fi
    sleep 3
  done
}

# ---------------------------------------------------------------------------
# Post-start — realm + user bootstrap (idempotent)
# ---------------------------------------------------------------------------
get_admin_token() {
  local token
  token=$(curl "${CURL_OPTS[@]}" -X POST \
    "$KC_BASE_URL/realms/master/protocol/openid-connect/token" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASS}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    | jq -r '.access_token // empty')

  [[ -n "$token" ]] || {
    log "Admin token request failed — dumping Keycloak logs:"
    docker compose -f "$COMPOSE_FILE" logs --tail 200 keycloak 2>/dev/null || true
    die "Could not obtain admin token. Check KC_ADMIN_USER / KC_ADMIN_PASS."
  }
  echo "$token"
}

ensure_realm() {
  local token="$1"
  local realm="user"

  local http_code
  http_code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $token" \
    "$KC_BASE_URL/admin/realms/$realm")

  if [[ "$http_code" == "200" ]]; then
    ok "Realm '$realm' already exists — skipping"
    return
  fi

  log "Creating realm '$realm'..."
  local status
  status=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
    -X POST "$KC_BASE_URL/admin/realms" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{
      "realm":   "user",
      "enabled": true
    }')

  [[ "$status" =~ ^2 ]] || die "Failed to create realm '$realm' (HTTP $status)"
  ok "Realm '$realm' created"
}

ensure_user() {
  local token="$1"
  local realm="user"
  local username="platform-admin"
  local password="changeme"

  # Check if user already exists
  local existing
  existing=$(curl "${CURL_OPTS[@]}" \
    -H "Authorization: Bearer $token" \
    "$KC_BASE_URL/admin/realms/$realm/users?username=$username&exact=true" \
    | jq 'length')

  if [[ "$existing" -gt 0 ]]; then
    ok "User '$username' already exists in realm '$realm' — skipping"
    return
  fi

  log "Creating user '$username' in realm '$realm'..."
  # Create user (no embedded credentials — use separate credentials endpoint)
  local uid
  uid=$(curl "${CURL_OPTS[@]}" -X POST \
    "$KC_BASE_URL/admin/realms/$realm/users" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -D - \
    -d "{\"username\":\"$username\",\"enabled\":true}" \
    | grep -i '^Location:' | awk -F'/' '{print $NF}' | tr -d '\r')

  [[ -n "$uid" ]] || die "Could not determine new user ID for '$username'"

  # Set password via the dedicated credentials endpoint (not embedded in user JSON,
  # which is unreliable across Keycloak versions)
  local cred_status
  cred_status=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
    -X PUT "$KC_BASE_URL/admin/realms/$realm/users/$uid/reset-password" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"password\",\"value\":\"$password\",\"temporary\":false}")

  [[ "$cred_status" =~ ^2 ]] || die "Failed to set password for '$username' (HTTP $cred_status)"
  ok "User '$username' created with password set"
}

bootstrap_realm() {
  log "Bootstrapping realm and users..."
  local token
  token=$(get_admin_token)
  ensure_realm "$token"
  ensure_user  "$token"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== Keycloak one-shot setup ==="
  require_root
  install_docker
  prepare_dir
  download_compose
  generate_tls
  start_containers
  wait_for_keycloak
  bootstrap_realm
  ok "=== Keycloak setup complete: $KC_BASE_URL ==="
}

main "$@"