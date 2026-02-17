#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="keycloak-cluster"
BACKEND_IMAGE="fastapi-student-app:latest"
FRONTEND_IMAGE="frontend-student-app:latest"
KEYCLOAK_URL="https://idp.keycloak.com:31111"
REALM="student-mgmt"

# Flags
SKIP_LOCAL_TESTS=false
SKIP_BUILD=false
ONLY_DEPLOY=false
ONLY_TEST_DEPLOYED=false

for arg in "$@"; do
  case "$arg" in
    --skip-local-tests) SKIP_LOCAL_TESTS=true ;;
    --skip-build) SKIP_BUILD=true ;;
    --only-deploy) ONLY_DEPLOY=true ;;
    --only-test-deployed) ONLY_TEST_DEPLOYED=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

cleanup() {
  pkill -f "port-forward.*fastapi-app" 2>/dev/null || true
  pkill -f "port-forward.*frontend-app" 2>/dev/null || true
}
trap cleanup EXIT

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
echo "  Deploy & Test Pipeline"
echo "============================================"
echo ""

# ---- Step 1: Build Docker images ----
if [ "$SKIP_BUILD" = false ] && [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 1: Building Docker images..."
  mkdir -p "$PROJECT_DIR/backend/certs"
  cp "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/backend/certs/ca.crt"
  docker build -t "$BACKEND_IMAGE" "$PROJECT_DIR/backend"
  rm -rf "$PROJECT_DIR/backend/certs"

  cd "$PROJECT_DIR/frontend"
  npm ci --silent
  docker build -t "$FRONTEND_IMAGE" "$PROJECT_DIR/frontend"
  echo ""
fi

# ---- Step 2: Load images to Kind ----
if [ "$SKIP_BUILD" = false ] && [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 2: Loading images to Kind cluster..."
  kind load docker-image "$BACKEND_IMAGE" --name "$CLUSTER_NAME"
  kind load docker-image "$FRONTEND_IMAGE" --name "$CLUSTER_NAME"
  echo ""
fi

# ---- Step 3: Deploy infrastructure ----
if [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 3: Deploying infrastructure..."

  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  echo "    Node IP: $NODE_IP"

  # Deploy Redis
  echo "    Deploying Redis..."
  kubectl apply -f "$PROJECT_DIR/keycloak/redis/redis-deployment.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/redis/redis-service.yaml"

  # Deploy App PostgreSQL
  echo "    Deploying App PostgreSQL..."
  kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-secret.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-deployment.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-service.yaml"

  wait_for_pods "app=redis" 120
  wait_for_pods "app=app-postgresql" 120

  # Deploy FastAPI backend
  echo "    Deploying FastAPI backend..."
  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-config.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-secret.yaml"
  sed "s/__NODE_IP__/$NODE_IP/g" "$PROJECT_DIR/keycloak/fastapi-app/app-deployment.yaml" \
    | kubectl apply -f -
  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-service.yaml"

  wait_for_pods "app=fastapi-app" 180

  # Deploy frontend
  echo "    Deploying frontend..."
  kubectl apply -f "$PROJECT_DIR/keycloak/frontend/frontend-deployment.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/frontend/frontend-service.yaml"

  wait_for_pods "app=frontend-app" 120

  # Update Keycloak client redirect URIs
  echo "    Updating Keycloak client redirect URIs..."
  ADMIN_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" -d "password=admin" -d "grant_type=password" -d "client_id=admin-cli" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

  CLIENT_INTERNAL_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=student-app" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

  curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_INTERNAL_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"student-app\",
      \"redirectUris\": [\"http://localhost:8000/api/auth/callback\", \"http://localhost:30000/api/auth/callback\"],
      \"webOrigins\": [\"http://localhost:8000\", \"http://localhost:30000\"],
      \"attributes\": {
        \"pkce.code.challenge.method\": \"S256\",
        \"post.logout.redirect.uris\": \"http://localhost:30000/login##http://localhost:8000/login\"
      }
    }" -o /dev/null
  echo ""
fi

if [ "$ONLY_DEPLOY" = true ]; then
  echo "==> Deploy complete (--only-deploy). Skipping tests."
  echo ""
  echo "==> Pod status:"
  kubectl get pods -n keycloak
  echo ""
  echo "==> Services:"
  kubectl get svc -n keycloak
  exit 0
fi

# ---- Step 4: Seed deployed DB ----
if [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 4: Seeding deployed database..."
  ADMIN_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" -d "password=admin" -d "grant_type=password" -d "client_id=admin-cli" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

  STUDENT_KC_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=student-user&exact=true" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

  FASTAPI_POD=$(kubectl get pod -n keycloak -l app=fastapi-app -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n keycloak "$FASTAPI_POD" -- python -c "
from app.database import SessionLocal
from app.models import Student, Department
db = SessionLocal()
if db.query(Department).count() == 0:
    for d in [
        {'name': 'Computer Science', 'description': 'CS department'},
        {'name': 'Mathematics', 'description': 'Math department'},
        {'name': 'Physics', 'description': 'Physics department'},
    ]:
        db.add(Department(**d))
    db.commit()
kc_id = '${STUDENT_KC_ID}'
cs = db.query(Department).filter(Department.name == 'Computer Science').first()
dept_id = cs.id if cs else None
if not db.query(Student).filter(Student.keycloak_user_id == kc_id).first():
    db.add(Student(name='Student User', email='student-user@example.com', keycloak_user_id=kc_id, department_id=dept_id))
if not db.query(Student).filter(Student.email == 'other-student@example.com').first():
    db.add(Student(name='Other Student', email='other-student@example.com', department_id=dept_id))
db.commit()
db.close()
print('Database seeded')
" 2>&1 | grep -v "^Defaulted"
  echo ""
fi

# ---- Step 5: Test deployed ----
echo "==> Step 5: Running E2E tests against deployed app..."

# Check if frontend is accessible via NodePort
for i in $(seq 1 15); do
  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:30000/" 2>/dev/null | grep -qE "200|301|302"; then break; fi
  sleep 1
done

cd "$PROJECT_DIR/frontend"
npm ci --silent 2>/dev/null || true
APP_URL=http://localhost:30000 npx playwright test --reporter=html || {
  echo "    Deployed tests failed!"
  echo ""
  echo "==> Pod status:"
  kubectl get pods -n keycloak
  exit 1
}
echo ""

# ---- Step 6: Report ----
echo "============================================"
echo "  Pipeline Complete - All Tests Passed!"
echo "============================================"
echo ""
echo "==> Pod status:"
kubectl get pods -n keycloak
echo ""
echo "==> Service endpoints:"
kubectl get svc -n keycloak
echo ""
echo "==> App URLs:"
echo "    Frontend: http://localhost:30000"
echo "    Keycloak: https://idp.keycloak.com:31111"
echo ""
echo "==> Test report: $PROJECT_DIR/frontend/playwright-report/index.html"
