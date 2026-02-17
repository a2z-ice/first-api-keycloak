#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# clean-deploy-test.sh
#
# Single script that performs a full clean → deploy → E2E test cycle.
#
# Steps:
#   1. Clean up existing cluster, certs, build artifacts
#   2. Generate TLS certificates
#   3. Create Kind cluster
#   4. Deploy Keycloak (PostgreSQL + StatefulSet + realm setup)
#   5. Build & deploy backend and frontend
#   6. Seed the database
#   7. Run all Playwright E2E tests
#
# Prerequisites:
#   - 127.0.0.1 idp.keycloak.com in /etc/hosts
#   - Docker, kind, kubectl, python3, node/npm, openssl installed
#   - Playwright browsers installed (npx playwright install)
#
# Usage:
#   ./scripts/clean-deploy-test.sh
###############################################################################

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="keycloak-cluster"
BACKEND_IMAGE="fastapi-student-app:latest"
FRONTEND_IMAGE="frontend-student-app:latest"
KEYCLOAK_URL="https://idp.keycloak.com:31111"
REALM="student-mgmt"
CLIENT_ID="student-app"
DEPLOYED_PORT=30000

# Track background processes for cleanup
CLEANUP_PIDS=()

cleanup_on_exit() {
  echo ""
  echo "==> Cleaning up background processes..."
  for pid in "${CLEANUP_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  pkill -f "port-forward.*frontend-app" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

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

wait_for_url() {
  local url="$1"
  local label="$2"
  local max_wait="${3:-60}"
  echo "    Waiting for ${label} at ${url}..."
  for i in $(seq 1 "$max_wait"); do
    if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -qE "200|301|302"; then
      echo "    ${label} is ready!"
      return 0
    fi
    sleep 1
  done
  echo "    ERROR: ${label} not reachable after ${max_wait}s"
  return 1
}

get_admin_token() {
  curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" -d "password=admin" -d "grant_type=password" -d "client_id=admin-cli" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

echo "╔══════════════════════════════════════════════╗"
echo "║   Clean → Deploy → Test (All-in-One)        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ================================================================
# PHASE 1: CLEANUP
# ================================================================
echo "━━━ PHASE 1: CLEANUP ━━━"
echo ""

# Delete existing Kind cluster
if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "==> Deleting Kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "==> No existing Kind cluster found."
fi

# Remove generated certificates
echo "==> Removing old certificates..."
rm -f "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/certs/ca.key"
rm -f "$PROJECT_DIR/certs/tls.crt" "$PROJECT_DIR/certs/tls.key"
rm -f "$PROJECT_DIR/certs/tls.csr" "$PROJECT_DIR/certs/ca.srl"

# Remove build artifacts
rm -f "$PROJECT_DIR/backend/students.db"
rm -rf "$PROJECT_DIR/backend/certs"
rm -rf "$PROJECT_DIR/frontend/dist"
rm -rf "$PROJECT_DIR/frontend/playwright-report"
rm -rf "$PROJECT_DIR/frontend/test-results"

echo "==> Cleanup done."
echo ""

# ================================================================
# PHASE 2: GENERATE TLS CERTIFICATES
# ================================================================
echo "━━━ PHASE 2: GENERATE TLS CERTIFICATES ━━━"
echo ""

bash "$PROJECT_DIR/certs/generate-certs.sh"
echo ""

# ================================================================
# PHASE 3: CREATE KIND CLUSTER
# ================================================================
echo "━━━ PHASE 3: CREATE KIND CLUSTER ━━━"
echo ""

echo "==> Creating Kind cluster '${CLUSTER_NAME}'..."
kind create cluster --name "$CLUSTER_NAME" --config "$PROJECT_DIR/cluster/kind-config.yaml"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""

# ================================================================
# PHASE 4: DEPLOY INFRASTRUCTURE (Namespace, TLS, PostgreSQL, Keycloak)
# ================================================================
echo "━━━ PHASE 4: DEPLOY INFRASTRUCTURE ━━━"
echo ""

# Create namespace
echo "==> Creating namespace..."
kubectl apply -f "$PROJECT_DIR/cluster/namespace.yaml"

# Create TLS secret
echo "==> Creating TLS secret..."
kubectl create secret generic keycloak-tls \
  --namespace keycloak \
  --from-file=tls.crt="$PROJECT_DIR/certs/tls.crt" \
  --from-file=tls.key="$PROJECT_DIR/certs/tls.key" \
  --from-file=ca.crt="$PROJECT_DIR/certs/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy Keycloak PostgreSQL
echo "==> Deploying Keycloak PostgreSQL..."
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-secret.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-deployment.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/postgresql/postgresql-service.yaml"
echo "    Waiting for Keycloak PostgreSQL..."
wait_for_pods "app=postgresql" 120

# Deploy Keycloak
echo "==> Deploying Keycloak (3-replica StatefulSet)..."
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-secret.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-config.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-headless-service.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-nodeport-service.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/keycloak-statefulset.yaml"
echo "    Waiting for Keycloak pods (this may take a few minutes)..."
wait_for_pods "app=keycloak" 300

# Wait for Keycloak HTTP readiness
echo "==> Waiting for Keycloak API readiness..."
bash "$PROJECT_DIR/scripts/wait-for-keycloak.sh"

# Configure realm, client, users
echo "==> Configuring Keycloak realm..."
bash "$PROJECT_DIR/keycloak/realm-config/realm-setup.sh"
echo ""

# ================================================================
# PHASE 5: BUILD & DEPLOY APPLICATION
# ================================================================
echo "━━━ PHASE 5: BUILD & DEPLOY APPLICATION ━━━"
echo ""

# --- Setup Python venv (needed for local tools like create-test-data.py) ---
echo "==> Setting up Python environment..."
cd "$PROJECT_DIR/backend"
# Always recreate venv to avoid stale interpreter paths
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install -q -r requirements.txt
cd "$PROJECT_DIR"

# --- Build backend Docker image ---
echo "==> Building backend Docker image..."
mkdir -p "$PROJECT_DIR/backend/certs"
cp "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/backend/certs/ca.crt"
docker build -t "$BACKEND_IMAGE" "$PROJECT_DIR/backend"
rm -rf "$PROJECT_DIR/backend/certs"

# --- Build frontend Docker image ---
echo "==> Building frontend Docker image..."
cd "$PROJECT_DIR/frontend"
npm ci --silent
docker build -t "$FRONTEND_IMAGE" "$PROJECT_DIR/frontend"
cd "$PROJECT_DIR"

# --- Load images to Kind ---
echo "==> Loading images to Kind cluster..."
kind load docker-image "$BACKEND_IMAGE" --name "$CLUSTER_NAME"
kind load docker-image "$FRONTEND_IMAGE" --name "$CLUSTER_NAME"

# --- Deploy Redis ---
echo "==> Deploying Redis..."
kubectl apply -f "$PROJECT_DIR/keycloak/redis/redis-deployment.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/redis/redis-service.yaml"

# --- Deploy App PostgreSQL ---
echo "==> Deploying App PostgreSQL..."
kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-secret.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-deployment.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-service.yaml"

# --- Wait for infra ---
echo "==> Waiting for Redis & App PostgreSQL..."
wait_for_pods "app=redis" 120
wait_for_pods "app=app-postgresql" 120

# --- Deploy FastAPI backend (substitute node IP for hostAliases) ---
echo "==> Deploying FastAPI backend (3 replicas)..."
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "    Node IP: ${NODE_IP}"

kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-config.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-secret.yaml"
sed "s/__NODE_IP__/${NODE_IP}/g" "$PROJECT_DIR/keycloak/fastapi-app/app-deployment.yaml" | kubectl apply -f -
kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-service.yaml"

echo "    Waiting for FastAPI pods..."
wait_for_pods "app=fastapi-app" 180

# --- Deploy frontend ---
echo "==> Deploying frontend (3 replicas)..."
kubectl apply -f "$PROJECT_DIR/keycloak/frontend/frontend-deployment.yaml"
kubectl apply -f "$PROJECT_DIR/keycloak/frontend/frontend-service.yaml"

echo "    Waiting for frontend pods..."
wait_for_pods "app=frontend-app" 120

# --- Update Keycloak client redirect URIs for deployed port ---
echo "==> Updating Keycloak client redirect URIs..."
ADMIN_TOKEN=$(get_admin_token)

CLIENT_INTERNAL_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

HTTP_CODE=$(curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_INTERNAL_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"clientId\": \"${CLIENT_ID}\",
    \"redirectUris\": [\"http://localhost:8000/api/auth/callback\", \"http://localhost:${DEPLOYED_PORT}/api/auth/callback\", \"http://localhost:5173/api/auth/callback\"],
    \"webOrigins\": [\"http://localhost:8000\", \"http://localhost:${DEPLOYED_PORT}\", \"http://localhost:5173\"],
    \"attributes\": {
      \"pkce.code.challenge.method\": \"S256\",
      \"post.logout.redirect.uris\": \"http://localhost:${DEPLOYED_PORT}/login##http://localhost:5173/login##http://localhost:8000/login\"
    }
  }" -o /dev/null -w "%{http_code}")
echo "    Keycloak client updated (HTTP ${HTTP_CODE})"
echo ""

# ================================================================
# PHASE 6: SEED DATABASE
# ================================================================
echo "━━━ PHASE 6: SEED DATABASE ━━━"
echo ""

ADMIN_TOKEN=$(get_admin_token)
STUDENT_KC_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=student-user&exact=true" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

echo "    Student Keycloak ID: ${STUDENT_KC_ID}"

FASTAPI_POD=$(kubectl get pod -n keycloak -l app=fastapi-app -o jsonpath='{.items[0].metadata.name}')
echo "    Seeding via pod: ${FASTAPI_POD}"

kubectl exec -n keycloak "$FASTAPI_POD" -c fastapi-app -- python -c "
from app.database import SessionLocal
from app.models import Student, Department
db = SessionLocal()

# Seed departments
if db.query(Department).count() == 0:
    for d in [
        {'name': 'Computer Science', 'description': 'CS department'},
        {'name': 'Mathematics', 'description': 'Math department'},
        {'name': 'Physics', 'description': 'Physics department'},
    ]:
        db.add(Department(**d))
    db.commit()
    print('Departments seeded')
else:
    print(f'Departments exist: {db.query(Department).count()}')

# Seed students
cs = db.query(Department).filter(Department.name == 'Computer Science').first()
did = cs.id if cs else None
kc_id = '${STUDENT_KC_ID}'

if not db.query(Student).filter(Student.keycloak_user_id == kc_id).first():
    db.add(Student(name='Student User', email='student-user@example.com', keycloak_user_id=kc_id, department_id=did))
    print('Created: Student User')
else:
    print('Exists: Student User')

if not db.query(Student).filter(Student.email == 'other-student@example.com').first():
    db.add(Student(name='Other Student', email='other-student@example.com', department_id=did))
    print('Created: Other Student')
else:
    print('Exists: Other Student')

db.commit()
db.close()
"
echo ""

# ================================================================
# PHASE 7: VERIFY DEPLOYMENT
# ================================================================
echo "━━━ PHASE 7: VERIFY DEPLOYMENT ━━━"
echo ""

echo "==> Pod status:"
kubectl get pods -n keycloak
echo ""
echo "==> Services:"
kubectl get svc -n keycloak
echo ""

# Verify frontend is reachable
wait_for_url "http://localhost:${DEPLOYED_PORT}/" "Frontend" 30 || {
  echo "    Frontend not reachable via NodePort, starting port-forward..."
  kubectl port-forward -n keycloak svc/frontend-app ${DEPLOYED_PORT}:80 &
  CLEANUP_PIDS+=($!)
  sleep 3
  wait_for_url "http://localhost:${DEPLOYED_PORT}/" "Frontend (port-forward)" 15
}

# Verify API health through frontend proxy
wait_for_url "http://localhost:${DEPLOYED_PORT}/api/health" "Backend API" 15

echo ""

# ================================================================
# PHASE 8: RUN PLAYWRIGHT E2E TESTS
# ================================================================
echo "━━━ PHASE 8: RUN PLAYWRIGHT E2E TESTS ━━━"
echo ""

cd "$PROJECT_DIR/frontend"

# Ensure Playwright browsers are installed
echo "==> Ensuring Playwright browsers are installed..."
npx playwright install chromium --with-deps 2>/dev/null || npx playwright install chromium

echo ""
echo "==> Running all Playwright E2E tests against http://localhost:${DEPLOYED_PORT}..."
echo ""

APP_URL="http://localhost:${DEPLOYED_PORT}" npx playwright test --reporter=html,list
TEST_EXIT=$?

echo ""

if [ $TEST_EXIT -ne 0 ]; then
  echo "╔══════════════════════════════════════════════╗"
  echo "║   TESTS FAILED!                              ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  echo "  HTML report: $PROJECT_DIR/frontend/playwright-report/index.html"
  echo ""
  echo "  Pod status:"
  kubectl get pods -n keycloak
  echo ""
  echo "  Recent FastAPI logs:"
  FASTAPI_POD=$(kubectl get pod -n keycloak -l app=fastapi-app -o jsonpath='{.items[0].metadata.name}')
  kubectl logs -n keycloak "$FASTAPI_POD" -c fastapi-app --tail=30 2>/dev/null || true
  exit 1
fi

# ================================================================
# REPORT
# ================================================================
echo "╔══════════════════════════════════════════════╗"
echo "║   All Tests Passed!                          ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Pod status:"
kubectl get pods -n keycloak
echo ""
echo "  Services:"
kubectl get svc -n keycloak
echo ""
echo "  URLs:"
echo "    Frontend:  http://localhost:${DEPLOYED_PORT}"
echo "    Keycloak:  ${KEYCLOAK_URL}"
echo ""
echo "  Test report: $PROJECT_DIR/frontend/playwright-report/index.html"
echo ""
echo "  Test users:"
echo "    admin-user / admin123"
echo "    student-user / student123"
echo "    staff-user / staff123"
echo ""
