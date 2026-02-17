#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# clean-and-redeploy.sh
#
# Full clean slate: tear down cluster, regenerate everything, build, deploy,
# and run E2E tests against the deployed app.
#
# Usage:
#   ./scripts/clean-and-redeploy.sh
###############################################################################

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="keycloak-cluster"

# Wait for pods matching a label to exist and become ready
wait_for_pods() {
  local label="$1"
  local timeout="${2:-120}"
  echo "    Waiting for pods (${label}) to be scheduled..."
  for i in $(seq 1 30); do
    if kubectl get pods -n keycloak -l "$label" 2>/dev/null | grep -q .; then
      break
    fi
    sleep 1
  done
  kubectl wait --namespace keycloak --for=condition=ready pod -l "$label" --timeout="${timeout}s"
}

echo "============================================"
echo "  Clean & Redeploy Pipeline"
echo "============================================"
echo ""

# ================================================================
# PHASE 1: CLEANUP
# ================================================================
echo "━━━ PHASE 1: CLEANUP ━━━"
echo ""

# Kill any leftover port-forwards or local app
pkill -f "port-forward.*fastapi-app" 2>/dev/null || true
pkill -f "uvicorn app.main:app" 2>/dev/null || true
docker stop redis-local 2>/dev/null && docker rm redis-local 2>/dev/null || true

# Delete Kind cluster
if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "==> Deleting Kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "==> No Kind cluster '${CLUSTER_NAME}' found."
fi

# Remove generated certificates
echo "==> Removing generated certificates..."
rm -f "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/certs/ca.key"
rm -f "$PROJECT_DIR/certs/tls.crt" "$PROJECT_DIR/certs/tls.key"
rm -f "$PROJECT_DIR/certs/tls.csr" "$PROJECT_DIR/certs/ca.srl"

# Remove SQLite database and Docker build artifacts
rm -f "$PROJECT_DIR/fastapi-app/students.db"
rm -rf "$PROJECT_DIR/fastapi-app/certs"

echo "==> Cleanup complete!"
echo ""

# ================================================================
# PHASE 2: SETUP (certs, cluster, Keycloak, venv)
# ================================================================
echo "━━━ PHASE 2: SETUP ━━━"
echo ""

# Step 1: Generate TLS certificates
echo "==> Generating TLS certificates..."
bash "$PROJECT_DIR/certs/generate-certs.sh"
echo ""

# Step 2: Create Kind cluster (now includes port 32000)
echo "==> Creating Kind cluster..."
kind create cluster --name "$CLUSTER_NAME" --config "$PROJECT_DIR/cluster/kind-config.yaml"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""

# Step 3: Create namespace
echo "==> Creating namespace..."
kubectl apply -f "$PROJECT_DIR/cluster/namespace.yaml"
echo ""

# Step 4: Create TLS secret (with ca.crt)
echo "==> Creating TLS secret..."
kubectl create secret generic keycloak-tls \
  --namespace keycloak \
  --from-file=tls.crt="$PROJECT_DIR/certs/tls.crt" \
  --from-file=tls.key="$PROJECT_DIR/certs/tls.key" \
  --from-file=ca.crt="$PROJECT_DIR/certs/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
echo ""

# Step 5: Deploy PostgreSQL (for Keycloak)
echo "==> Deploying Keycloak PostgreSQL..."
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-secret.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-deployment.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-service.yaml"
wait_for_pods "app=postgresql" 120
echo ""

# Step 6: Deploy Keycloak
echo "==> Deploying Keycloak (3 replicas)..."
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-secret.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-config.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-headless-service.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-nodeport-service.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-statefulset.yaml"
wait_for_pods "app=keycloak" 300
echo ""

# Step 7: Configure realm
echo "==> Configuring Keycloak realm..."
bash "$PROJECT_DIR/scripts/wait-for-keycloak.sh"
bash "$PROJECT_DIR/keycloak/realm-config/realm-setup.sh"
echo ""

# Step 8: Setup Python venv (if missing)
echo "==> Setting up Python environment..."
cd "$PROJECT_DIR/fastapi-app"
if [ ! -d "venv" ]; then
  python3 -m venv venv
fi
source venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt
# Install playwright browsers if needed
playwright install chromium 2>/dev/null || true
echo ""

echo "==> Setup complete!"
echo ""

# ================================================================
# PHASE 3: BUILD, DEPLOY APP, AND TEST
# ================================================================
echo "━━━ PHASE 3: BUILD, DEPLOY & TEST ━━━"
echo ""

exec bash "$PROJECT_DIR/scripts/build-test-deploy.sh" --skip-local
