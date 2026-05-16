#!/usr/bin/env bash
# =============================================================================
# config-keycloak-front.sh — Create the ecom-frontend public client in Keycloak
# Run this standalone on the VM without restarting anything.
# =============================================================================
set -Eeuo pipefail
trap 'echo "[ERROR] line ${LINENO} exited with $?" >&2' ERR

KC_BASE_URL="https://127.0.0.1:8443"
KC_HOSTNAME="ecom-apim-formation.azure-api.net"
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
  log "Client 'ecom-frontend' exists — updating URLs and disabling PKCE..."
  client_uuid=$(curl "${auth[@]}" \
    "$KC_BASE_URL/admin/realms/user/clients?clientId=ecom-frontend" \
    | jq -r '.[0].id')
  curl "${auth[@]}" -X PUT "$KC_BASE_URL/admin/realms/user/clients/$client_uuid" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "ecom-frontend",                                                                                                                                                                   
      "enabled": true,                                                                                                                                                                          
      "publicClient": true,                                                                                                                                                                     
      "directAccessGrantsEnabled": true,                                                                                                                                                        
      "standardFlowEnabled": true, 
      "rootUrl": "https://20.43.59.226",
      "baseUrl": "/",
      "redirectUris": ["https://20.43.59.226/*"],
      "webOrigins": ["https://20.43.59.226"],
      "protocol": "openid-connect", 
      "attributes": {"pkce.code.challenge.method": ""}
    }' \
    && log "✓ URLs updated + PKCE disabled on 'ecom-frontend'" || die "Failed to update client"
else
  curl "${auth[@]}" -X POST "$KC_BASE_URL/admin/realms/user/clients" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "ecom-frontend",
      "enabled": true,
      "publicClient": true,
      "directAccessGrantsEnabled": true,
      "standardFlowEnabled": true,
      "rootUrl": "https://20.43.59.226",
      "baseUrl": "/",
      "redirectUris": ["https://20.43.59.226/*"],
      "webOrigins": ["https://20.43.59.226"],
      "protocol": "openid-connect"
    }' -o /dev/null \
    && log "✓ client 'ecom-frontend' created" || die "Failed to create client"
fi

# --- Configure realm frontend URL and enable self-registration ---
log "Configuring realm 'user' (frontendUrl + registration)..."
curl "${auth[@]}" -X PUT "$KC_BASE_URL/admin/realms/user" \
  -H "Content-Type: application/json" \
  -d "{\"registrationAllowed\": true, \"attributes\": {\"frontendUrl\": \"https://$KC_HOSTNAME/keycloak\"}}" -o /dev/null \
  && log "✓ realm configured (frontendUrl=$KC_HOSTNAME, registration=enabled)" || die "Failed to configure realm"

log "Done."