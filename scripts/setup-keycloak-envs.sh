#!/usr/bin/env bash
# setup-keycloak-envs.sh — Create dev and prod Keycloak clients for multi-environment setup
set -euo pipefail

KEYCLOAK_URL="https://idp.keycloak.com:31111"
REALM="student-mgmt"
ADMIN_USER="admin"
ADMIN_PASS="admin"

echo "==> Setting up Keycloak clients for dev and prod environments..."

# ---- Get admin token ----
echo "    Authenticating with Keycloak..."
TOKEN_RESPONSE=$(curl -sf --insecure \
    -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d "grant_type=password" \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token")

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [ -z "${ACCESS_TOKEN}" ]; then
    echo "ERROR: Failed to get Keycloak admin token"
    exit 1
fi

echo "    Got admin token."

# ---- Helper: create or update a Keycloak client ----
create_or_update_client() {
    local CLIENT_ID="$1"
    local REDIRECT_URI="$2"
    local WEB_ORIGIN="$3"
    local CLIENT_SECRET="$4"

    echo "    Processing client: ${CLIENT_ID}..."

    # Check if client already exists
    EXISTING=$(curl -sf --insecure \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
        | python3 -c "import sys,json; clients=json.load(sys.stdin); print(clients[0]['id'] if clients else '')" 2>/dev/null || echo "")

    CLIENT_PAYLOAD=$(cat <<EOF
{
  "clientId": "${CLIENT_ID}",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "secret": "${CLIENT_SECRET}",
  "redirectUris": ["${REDIRECT_URI}"],
  "webOrigins": ["${WEB_ORIGIN}"],
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "attributes": {
    "pkce.code.challenge.method": "S256"
  }
}
EOF
)

    if [ -n "${EXISTING}" ]; then
        echo "      Updating existing client ${CLIENT_ID} (id: ${EXISTING})..."
        curl -sf --insecure \
            -X PUT \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${CLIENT_PAYLOAD}" \
            "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${EXISTING}" \
            && echo "      Updated." || echo "      Update failed (non-fatal)."
    else
        echo "      Creating new client ${CLIENT_ID}..."
        curl -sf --insecure \
            -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${CLIENT_PAYLOAD}" \
            "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
            && echo "      Created." || { echo "      Creation failed."; exit 1; }
    fi

    # Assign realm roles to the client's service account (if needed)
    # Roles (admin, staff, student) are defined as realm roles and assigned to users
}

# ---- Create dev client ----
create_or_update_client \
    "student-app-dev" \
    "http://dev.student.local:8080/api/auth/callback" \
    "http://dev.student.local:8080" \
    "student-app-dev-secret"

# ---- Create prod client ----
create_or_update_client \
    "student-app-prod" \
    "http://prod.student.local:8080/api/auth/callback" \
    "http://prod.student.local:8080" \
    "student-app-prod-secret"

echo ""
echo "==> Keycloak environment clients created:"
echo "    - student-app-dev  → http://dev.student.local:8080"
echo "    - student-app-prod → http://prod.student.local:8080"
echo ""
echo "    Add to /etc/hosts:"
echo "      127.0.0.1 dev.student.local"
echo "      127.0.0.1 prod.student.local"
echo ""
