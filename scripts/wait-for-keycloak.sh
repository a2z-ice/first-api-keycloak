#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-https://idp.keycloak.com:31111}"
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL=5
ELAPSED=0

echo "==> Waiting for Keycloak at ${KEYCLOAK_URL} (max ${MAX_WAIT}s)..."

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -sk "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" 2>/dev/null | grep -q 'authorization_endpoint'; then
        echo "==> Keycloak is ready! (after ${ELAPSED}s)"
        exit 0
    fi
    echo "    Not ready yet... (${ELAPSED}s elapsed)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "==> ERROR: Keycloak did not become ready within ${MAX_WAIT}s"
exit 1
