#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-https://idp.keycloak.com:31111}"
APP_URL="${APP_URL:-http://localhost:8000}"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    if eval "$cmd" > /dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Deployment Verification ==="
echo ""

echo "[Kubernetes]"
check "Keycloak namespace exists" "kubectl get namespace keycloak"
check "PostgreSQL pod is running" "kubectl get pods -n keycloak -l app=postgresql --field-selector=status.phase=Running | grep -q postgresql"
check "Keycloak pods are running" "kubectl get pods -n keycloak -l app=keycloak --field-selector=status.phase=Running | grep -c keycloak | grep -q 3"

echo ""
echo "[Keycloak]"
check "Keycloak health endpoint" "curl -sk ${KEYCLOAK_URL}/health/ready | grep -q UP"
check "Keycloak OpenID config" "curl -sk ${KEYCLOAK_URL}/realms/student-mgmt/.well-known/openid-configuration | grep -q authorization_endpoint"

echo ""
echo "[FastAPI App]"
check "FastAPI login page" "curl -s ${APP_URL}/login-page | grep -q 'Login with Keycloak'"
check "FastAPI redirects unauthenticated" "curl -s -o /dev/null -w '%{http_code}' ${APP_URL}/ | grep -q 302"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [ $FAIL -gt 0 ]; then
    exit 1
fi
