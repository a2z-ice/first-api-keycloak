#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTER_NAME="keycloak-cluster"

echo "============================================"
echo " Keycloak OAuth2.1 Student Management Setup"
echo "============================================"
echo ""

# ---- Step 1: Generate TLS Certificates ----
echo "==> Step 1: Generating TLS certificates..."
bash "$PROJECT_DIR/certs/generate-certs.sh"
echo ""

# ---- Step 2: Create Kind Cluster ----
echo "==> Step 2: Creating Kind cluster..."
if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo "    Cluster '${CLUSTER_NAME}' already exists, skipping."
else
    kind create cluster --name "$CLUSTER_NAME" --config "$PROJECT_DIR/cluster/kind-config.yaml"
fi
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""

# ---- Step 3: Create Namespace ----
echo "==> Step 3: Creating namespace..."
kubectl apply -f "$PROJECT_DIR/cluster/namespace.yaml"
echo ""

# ---- Step 4: Create TLS Secret ----
echo "==> Step 4: Creating TLS secret in cluster..."
kubectl create secret generic keycloak-tls \
    --namespace keycloak \
    --from-file=tls.crt="$PROJECT_DIR/certs/tls.crt" \
    --from-file=tls.key="$PROJECT_DIR/certs/tls.key" \
    --from-file=ca.crt="$PROJECT_DIR/certs/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ---- Step 5: Deploy PostgreSQL ----
echo "==> Step 5: Deploying PostgreSQL..."
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-secret.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-deployment.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-service.yaml"
echo "    Waiting for PostgreSQL to be ready..."
kubectl wait --namespace keycloak --for=condition=ready pod -l app=postgresql --timeout=120s
echo ""

# ---- Step 6: Deploy Keycloak ----
echo "==> Step 6: Deploying Keycloak..."
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-secret.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-config.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-headless-service.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-nodeport-service.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-statefulset.yaml"
echo "    Waiting for Keycloak pods to be ready (this may take a few minutes)..."
kubectl wait --namespace keycloak --for=condition=ready pod -l app=keycloak --timeout=300s
echo ""

# ---- Step 7: Configure Realm ----
echo "==> Step 7: Configuring Keycloak realm..."
bash "$PROJECT_DIR/scripts/wait-for-keycloak.sh"
bash "$PROJECT_DIR/keycloak/realm-config/realm-setup.sh"
echo ""

# ---- Step 8: Setup Python Virtual Environment ----
echo "==> Step 8: Setting up Python environment..."
cd "$PROJECT_DIR/fastapi-app"

if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install -q -r requirements.txt
echo ""

# ---- Step 9: Initialize Database & Seed Data ----
echo "==> Step 9: Initializing database and seeding data..."
cd "$PROJECT_DIR/fastapi-app"
python3 "$PROJECT_DIR/scripts/create-test-data.py"
echo ""

echo "============================================"
echo " Setup Complete!"
echo "============================================"
echo ""
echo " Keycloak:  https://idp.keycloak.com:31111"
echo " Admin:     admin / admin"
echo ""
echo " To start the FastAPI app:"
echo "   cd fastapi-app"
echo "   source venv/bin/activate"
echo "   python run.py"
echo ""
echo " Then open: http://localhost:8000"
echo ""
echo " Make sure '127.0.0.1 idp.keycloak.com' is in /etc/hosts"
echo "============================================"
