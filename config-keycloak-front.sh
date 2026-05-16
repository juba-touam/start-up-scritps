#!/usr/bin/env bash
# =============================================================================
# config-keycloak-front.sh — Create the ecom-frontend public client in Keycloak
# Run this standalone on the VM without restarting anything.
# =============================================================================
set -Eeuo pipefail
trap 'echo "[ERROR] line ${LINENO} exited with $?" >&2' ERR

KC_BASE_URL="https://127.0.0.1:8443"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-adminpass}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "[$(date -u +%H:%M:%S)] ✗ $*" >&2; exit 1; }

# --- Get admin token ---
log "Obtaining admin token..."
token=$(curl -sk --max-time 10 -X POST \
  "$KC_BASE_URL/realms/master/protocol/openid-connect/token" \
  -d "username=$KC_ADMIN_USER" \
  -d "password=$KC_ADMIN_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  | jq -r '.access_token // empty')

[[ -n "$token" ]] || die "Could not get admin token — check KC_ADMIN_USER / KC_ADMIN_PASS"

auth=(-sk --max-time 10 -H "Authorization: Bearer $token")

# --- Create OAuth2 client for frontend (public SPA) ---
log "Creating OAuth2 client 'ecom-frontend'..."

client_exists=$(curl "${auth[@]}" \
  "$KC_BASE_URL/admin/realms/user/clients?clientId=ecom-frontend" \
  | jq 'length')

if [[ "$client_exists" -gt 0 ]]; then
  log "✓ client 'ecom-frontend' already exists"
else
  curl "${auth[@]}" -X POST "$KC_BASE_URL/admin/realms/user/clients" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "ecom-frontend",
      "enabled": true,
      "publicClient": true,
      "directAccessGrantsEnabled": true,
      "standardFlowEnabled": true,
      "rootUrl": "http://20.43.59.226",
      "baseUrl": "/",
      "redirectUris": ["http://20.43.59.226/*"],
      "webOrigins": ["http://20.43.59.226"],
      "protocol": "openid-connect"
    }' -o /dev/null \
    && log "✓ client 'ecom-frontend' created" || die "Failed to create client"
fi

# --- Enable user self-registration on realm 'user' ---
log "Enabling self-registration on realm 'user'..."
curl "${auth[@]}" -X PUT "$KC_BASE_URL/admin/realms/user" \
  -H "Content-Type: application/json" \
  -d '{"registrationAllowed": true}' -o /dev/null \
  && log "✓ self-registration enabled" || die "Failed to enable registration"

log "Done."
