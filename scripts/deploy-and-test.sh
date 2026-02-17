#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="keycloak-cluster"
IMAGE_NAME="fastapi-student-app:latest"
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

# ---- Step 1: Seed local DB ----
if [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 1: Seeding local database..."
  cd "$PROJECT_DIR/fastapi-app"
  if [ -d "venv" ]; then
    source venv/bin/activate
  fi
  python "$PROJECT_DIR/scripts/create-test-data.py"
  echo ""
fi

# ---- Step 2: Test local ----
if [ "$SKIP_LOCAL_TESTS" = false ] && [ "$ONLY_DEPLOY" = false ] && [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 2: Running local E2E tests..."
  cd "$PROJECT_DIR/fastapi-app"
  if [ -d "venv" ]; then
    source venv/bin/activate
  fi
  APP_URL=http://localhost:8000 pytest tests/test_e2e.py -v || {
    echo "    Local tests failed!"
    exit 1
  }
  echo ""
fi

# ---- Step 3: Build Docker image ----
if [ "$SKIP_BUILD" = false ] && [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 3: Building Docker image..."
  # Copy CA cert into build context
  mkdir -p "$PROJECT_DIR/fastapi-app/certs"
  cp "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/fastapi-app/certs/ca.crt"
  docker build -t "$IMAGE_NAME" "$PROJECT_DIR/fastapi-app"
  rm -rf "$PROJECT_DIR/fastapi-app/certs"
  echo ""
fi

# ---- Step 4: Load image to Kind ----
if [ "$SKIP_BUILD" = false ] && [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 4: Loading image to Kind cluster..."
  kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"
  echo ""
fi

# ---- Step 5: Deploy infrastructure ----
if [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 5: Deploying infrastructure..."

  # Get node IP for hostAliases
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

  # Wait for Redis and PostgreSQL
  wait_for_pods "app=redis" 120
  wait_for_pods "app=app-postgresql" 120

  # Deploy FastAPI app (substitute NODE_IP in deployment manifest)
  echo "    Deploying FastAPI app..."
  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-config.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-secret.yaml"
  sed "s/__NODE_IP__/$NODE_IP/g" "$PROJECT_DIR/keycloak/fastapi-app/app-deployment.yaml" \
    | kubectl apply -f -
  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-service.yaml"

  wait_for_pods "app=fastapi-app" 180

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
      \"redirectUris\": [\"http://localhost:8000/callback\", \"http://localhost:32000/callback\"],
      \"webOrigins\": [\"http://localhost:8000\", \"http://localhost:32000\"],
      \"attributes\": {
        \"pkce.code.challenge.method\": \"S256\",
        \"post.logout.redirect.uris\": \"http://localhost:8000/login-page##http://localhost:32000/login-page\"
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

# ---- Step 6: Seed deployed DB ----
if [ "$ONLY_TEST_DEPLOYED" = false ]; then
  echo "==> Step 6: Seeding deployed database..."
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

# ---- Step 7: Test deployed ----
echo "==> Step 7: Running E2E tests against deployed app..."

# Start port-forward
kubectl port-forward -n keycloak svc/fastapi-app 32000:8000 > /dev/null 2>&1 &
PF_PID=$!
for i in $(seq 1 15); do
  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:32000/login-page" 2>/dev/null | grep -q 200; then break; fi
  sleep 1
done

cd "$PROJECT_DIR/fastapi-app"
if [ -d "venv" ]; then
  source venv/bin/activate
fi
APP_URL=http://localhost:32000 pytest tests/test_e2e.py -v || {
  echo "    Deployed tests failed!"
  echo ""
  echo "==> Pod status:"
  kubectl get pods -n keycloak
  kill "$PF_PID" 2>/dev/null || true
  exit 1
}
kill "$PF_PID" 2>/dev/null || true
echo ""

# ---- Step 8: Report ----
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
echo "    Local:    http://localhost:8000"
echo "    Deployed: http://localhost:32000 (via port-forward)"
echo "    Keycloak: https://idp.keycloak.com:31111"
