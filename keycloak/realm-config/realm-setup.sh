#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-https://idp.keycloak.com:31111}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="student-mgmt"
CLIENT_ID="student-app"
CLIENT_SECRET="student-app-secret"

echo "==> Waiting for Keycloak to be ready..."
until curl -sk "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" | grep -q 'authorization_endpoint'; do
  echo "    Keycloak not ready yet, waiting..."
  sleep 5
done
echo "==> Keycloak is ready!"

# Get admin token
echo "==> Getting admin access token..."
ADMIN_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASS}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

AUTH="Authorization: Bearer ${ADMIN_TOKEN}"

# Create realm
echo "==> Creating realm '${REALM}'..."
curl -sk -X POST "${KEYCLOAK_URL}/admin/realms" \
  -H "${AUTH}" \
  -H "Content-Type: application/json" \
  -d "{
    \"realm\": \"${REALM}\",
    \"enabled\": true,
    \"registrationAllowed\": false,
    \"loginWithEmailAllowed\": true,
    \"sslRequired\": \"external\"
  }" || echo "    Realm may already exist"

# Create client
echo "==> Creating client '${CLIENT_ID}'..."
curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
  -H "${AUTH}" \
  -H "Content-Type: application/json" \
  -d "{
    \"clientId\": \"${CLIENT_ID}\",
    \"name\": \"Student Management App\",
    \"enabled\": true,
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"secret\": \"${CLIENT_SECRET}\",
    \"standardFlowEnabled\": true,
    \"directAccessGrantsEnabled\": false,
    \"serviceAccountsEnabled\": false,
    \"authorizationServicesEnabled\": false,
    \"redirectUris\": [\"http://localhost:8000/api/auth/callback\", \"http://localhost:30000/api/auth/callback\", \"http://localhost:5173/api/auth/callback\"],
    \"webOrigins\": [\"http://localhost:8000\", \"http://localhost:30000\", \"http://localhost:5173\"],
    \"attributes\": {
      \"pkce.code.challenge.method\": \"S256\",
      \"post.logout.redirect.uris\": \"http://localhost:30000/login##http://localhost:5173/login##http://localhost:8000/login\"
    }
  }" || echo "    Client may already exist"

# Get client internal ID
echo "==> Getting client internal ID..."
CLIENT_INTERNAL_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  -H "${AUTH}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

echo "    Client internal ID: ${CLIENT_INTERNAL_ID}"

# Create client roles
echo "==> Creating client roles..."
for ROLE in admin student staff; do
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_INTERNAL_ID}/roles" \
    -H "${AUTH}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${ROLE}\"}" || echo "    Role '${ROLE}' may already exist"
done

# Helper function to create user and assign role
create_user() {
  local USERNAME="$1"
  local PASSWORD="$2"
  local ROLE="$3"

  echo "==> Creating user '${USERNAME}' with role '${ROLE}'..."

  # Create user
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
    -H "${AUTH}" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"${USERNAME}\",
      \"enabled\": true,
      \"emailVerified\": true,
      \"email\": \"${USERNAME}@example.com\",
      \"firstName\": \"$(echo ${USERNAME} | cut -d'-' -f1 | sed 's/^./\U&/')\",
      \"lastName\": \"User\",
      \"credentials\": [{
        \"type\": \"password\",
        \"value\": \"${PASSWORD}\",
        \"temporary\": false
      }]
    }" || echo "    User '${USERNAME}' may already exist"

  # Get user ID
  USER_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=${USERNAME}&exact=true" \
    -H "${AUTH}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

  # Get role representation
  ROLE_REP=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_INTERNAL_ID}/roles/${ROLE}" \
    -H "${AUTH}")

  # Assign client role to user
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/clients/${CLIENT_INTERNAL_ID}" \
    -H "${AUTH}" \
    -H "Content-Type: application/json" \
    -d "[${ROLE_REP}]"

  echo "    User '${USERNAME}' created and assigned role '${ROLE}'"
}

# Create test users
create_user "admin-user" "admin123" "admin"
create_user "student-user" "student123" "student"
create_user "staff-user" "staff123" "staff"

echo ""
echo "==> Realm setup complete!"
echo "    Realm: ${REALM}"
echo "    Client: ${CLIENT_ID}"
echo "    Client Secret: ${CLIENT_SECRET}"
echo "    Users: admin-user, student-user, staff-user"
