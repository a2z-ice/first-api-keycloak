#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# build-test-deploy.sh
#
# All-in-one script: build, test locally, deploy to Kind, test deployed.
#
# Prerequisites:
#   - Kind cluster "keycloak-cluster" running with Keycloak deployed
#   - 127.0.0.1 idp.keycloak.com in /etc/hosts
#   - Docker, kind, kubectl, python3 installed
#   - Playwright browsers installed (playwright install)
#
# Usage:
#   ./scripts/build-test-deploy.sh                # Full pipeline
#   ./scripts/build-test-deploy.sh --skip-local   # Skip local app start + test
#   ./scripts/build-test-deploy.sh --deploy-only  # Build + deploy, no tests
#   ./scripts/build-test-deploy.sh --test-only    # Test deployed app only
###############################################################################

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="keycloak-cluster"
IMAGE_NAME="fastapi-student-app:latest"
KEYCLOAK_URL="https://idp.keycloak.com:31111"
REALM="student-mgmt"
CLIENT_ID="student-app"
DEPLOYED_PORT=32000
LOCAL_PORT=8000
REDIS_CONTAINER="redis-local"

SKIP_LOCAL=false
DEPLOY_ONLY=false
TEST_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --skip-local)  SKIP_LOCAL=true ;;
    --deploy-only) DEPLOY_ONLY=true ;;
    --test-only)   TEST_ONLY=true ;;
    --help|-h)
      echo "Usage: $0 [--skip-local] [--deploy-only] [--test-only]"
      echo ""
      echo "  --skip-local   Skip local Redis/app startup and local tests"
      echo "  --deploy-only  Build and deploy only, skip all tests"
      echo "  --test-only    Only run tests against already-deployed app"
      exit 0
      ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# Cleanup function
cleanup() {
  echo ""
  echo "==> Cleaning up background processes..."
  pkill -f "port-forward.*fastapi-app.*${DEPLOYED_PORT}" 2>/dev/null || true
  # Only stop local app/redis if we started them
  if [ "$SKIP_LOCAL" = false ] && [ "$TEST_ONLY" = false ]; then
    pkill -f "uvicorn app.main:app" 2>/dev/null || true
    docker stop "$REDIS_CONTAINER" 2>/dev/null || true
    docker rm "$REDIS_CONTAINER" 2>/dev/null || true
  fi
}
trap cleanup EXIT

activate_venv() {
  cd "$PROJECT_DIR/fastapi-app"
  if [ -d "venv" ]; then
    source venv/bin/activate
  fi
}

wait_for_url() {
  local url="$1"
  local label="$2"
  local max_wait="${3:-30}"
  echo "    Waiting for ${label}..."
  for i in $(seq 1 "$max_wait"); do
    if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q 200; then
      echo "    ${label} is ready!"
      return 0
    fi
    sleep 1
  done
  echo "    ERROR: ${label} not reachable after ${max_wait}s"
  return 1
}

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

get_admin_token() {
  curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" -d "password=admin" -d "grant_type=password" -d "client_id=admin-cli" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

echo "============================================"
echo "  Build - Test - Deploy Pipeline"
echo "============================================"
echo "  Cluster:  ${CLUSTER_NAME}"
echo "  Keycloak: ${KEYCLOAK_URL}"
echo "  Flags:    skip_local=${SKIP_LOCAL} deploy_only=${DEPLOY_ONLY} test_only=${TEST_ONLY}"
echo "============================================"
echo ""

# ================================================================
# PHASE 1: LOCAL TEST (optional)
# ================================================================
if [ "$SKIP_LOCAL" = false ] && [ "$TEST_ONLY" = false ] && [ "$DEPLOY_ONLY" = false ]; then
  echo "━━━ PHASE 1: LOCAL TEST ━━━"
  echo ""

  # Start Redis
  echo "==> Starting local Redis..."
  docker run -d --name "$REDIS_CONTAINER" -p 6379:6379 redis:7-alpine 2>/dev/null \
    || docker start "$REDIS_CONTAINER" 2>/dev/null || true
  for i in $(seq 1 10); do
    if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then break; fi
    sleep 1
  done

  # Seed local DB
  echo "==> Seeding local database..."
  activate_venv
  python "$PROJECT_DIR/scripts/create-test-data.py"

  # Start local app
  echo "==> Starting local FastAPI app..."
  activate_venv
  python run.py &
  LOCAL_APP_PID=$!
  wait_for_url "http://localhost:${LOCAL_PORT}/login-page" "Local app"

  # Run local tests
  echo ""
  echo "==> Running E2E tests against local app..."
  APP_URL="http://localhost:${LOCAL_PORT}" pytest tests/test_e2e.py -v || {
    echo "    LOCAL TESTS FAILED!"
    exit 1
  }

  # Stop local app
  kill $LOCAL_APP_PID 2>/dev/null || true
  docker stop "$REDIS_CONTAINER" 2>/dev/null || true
  docker rm "$REDIS_CONTAINER" 2>/dev/null || true

  echo ""
  echo "==> Local tests passed!"
  echo ""
fi

# ================================================================
# PHASE 2: BUILD + DEPLOY
# ================================================================
if [ "$TEST_ONLY" = false ]; then
  echo "━━━ PHASE 2: BUILD & DEPLOY ━━━"
  echo ""

  # Build Docker image
  echo "==> Building Docker image..."
  mkdir -p "$PROJECT_DIR/fastapi-app/certs"
  cp "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/fastapi-app/certs/ca.crt"
  docker build -t "$IMAGE_NAME" "$PROJECT_DIR/fastapi-app"
  rm -rf "$PROJECT_DIR/fastapi-app/certs"

  # Load to Kind
  echo ""
  echo "==> Loading image to Kind cluster..."
  kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"

  # Ensure TLS secret has ca.crt
  echo ""
  echo "==> Updating TLS secret..."
  kubectl create secret generic keycloak-tls \
    --namespace keycloak \
    --from-file=tls.crt="$PROJECT_DIR/certs/tls.crt" \
    --from-file=tls.key="$PROJECT_DIR/certs/tls.key" \
    --from-file=ca.crt="$PROJECT_DIR/certs/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Deploy Redis
  echo ""
  echo "==> Deploying Redis..."
  kubectl apply -f "$PROJECT_DIR/keycloak/redis/redis-deployment.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/redis/redis-service.yaml"

  # Deploy App PostgreSQL
  echo "==> Deploying App PostgreSQL..."
  kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-secret.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-deployment.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/app-postgresql/postgresql-service.yaml"

  # Wait for infra
  echo "==> Waiting for infrastructure..."
  wait_for_pods "app=redis" 120
  wait_for_pods "app=app-postgresql" 120

  # Deploy FastAPI (substitute node IP)
  echo ""
  echo "==> Deploying FastAPI app (3 replicas)..."
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  echo "    Node IP: ${NODE_IP}"

  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-config.yaml"
  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-secret.yaml"
  sed "s/__NODE_IP__/${NODE_IP}/g" "$PROJECT_DIR/keycloak/fastapi-app/app-deployment.yaml" | kubectl apply -f -
  kubectl apply -f "$PROJECT_DIR/keycloak/fastapi-app/app-service.yaml"

  echo "==> Waiting for FastAPI pods..."
  wait_for_pods "app=fastapi-app" 180

  # Update Keycloak client redirect URIs
  echo ""
  echo "==> Updating Keycloak client redirect URIs..."
  ADMIN_TOKEN=$(get_admin_token)

  CLIENT_INTERNAL_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

  HTTP_CODE=$(curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_INTERNAL_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"${CLIENT_ID}\",
      \"redirectUris\": [\"http://localhost:${LOCAL_PORT}/callback\", \"http://localhost:${DEPLOYED_PORT}/callback\"],
      \"webOrigins\": [\"http://localhost:${LOCAL_PORT}\", \"http://localhost:${DEPLOYED_PORT}\"],
      \"attributes\": {
        \"pkce.code.challenge.method\": \"S256\",
        \"post.logout.redirect.uris\": \"http://localhost:${LOCAL_PORT}/login-page##http://localhost:${DEPLOYED_PORT}/login-page\"
      }
    }" -o /dev/null -w "%{http_code}")
  echo "    Keycloak client updated (HTTP ${HTTP_CODE})"

  # Seed deployed DB
  echo ""
  echo "==> Seeding deployed database..."
  ADMIN_TOKEN=$(get_admin_token)
  STUDENT_KC_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=student-user&exact=true" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

  FASTAPI_POD=$(kubectl get pod -n keycloak -l app=fastapi-app -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n keycloak "$FASTAPI_POD" -c fastapi-app -- python -c "
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
    print('Departments seeded')
else:
    print(f'Departments exist: {db.query(Department).count()}')
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
  echo "==> Deploy complete!"
  echo ""
fi

if [ "$DEPLOY_ONLY" = true ]; then
  echo ""
  echo "==> Pod status:"
  kubectl get pods -n keycloak
  echo ""
  echo "==> Services:"
  kubectl get svc -n keycloak
  exit 0
fi

# ================================================================
# PHASE 3: TEST DEPLOYED APP
# ================================================================
echo "━━━ PHASE 3: TEST DEPLOYED APP ━━━"
echo ""

# Start port-forward
pkill -f "port-forward.*fastapi-app.*${DEPLOYED_PORT}" 2>/dev/null || true
kubectl port-forward -n keycloak svc/fastapi-app ${DEPLOYED_PORT}:8000 &
PF_PID=$!
sleep 3

wait_for_url "http://localhost:${DEPLOYED_PORT}/login-page" "Deployed app" || {
  kill $PF_PID 2>/dev/null || true
  exit 1
}

echo ""
echo "==> Running E2E tests against deployed app (http://localhost:${DEPLOYED_PORT})..."
activate_venv

APP_URL="http://localhost:${DEPLOYED_PORT}" pytest tests/test_e2e.py -v
TEST_EXIT=$?

kill $PF_PID 2>/dev/null || true

if [ $TEST_EXIT -ne 0 ]; then
  echo ""
  echo "    DEPLOYED TESTS FAILED!"
  echo ""
  kubectl get pods -n keycloak
  exit 1
fi

# ================================================================
# REPORT
# ================================================================
echo ""
echo "============================================"
echo "  All Tests Passed!"
echo "============================================"
echo ""
echo "  Pod status:"
kubectl get pods -n keycloak
echo ""
echo "  Services:"
kubectl get svc -n keycloak
echo ""
echo "  URLs:"
echo "    Local:    http://localhost:${LOCAL_PORT}"
echo "    Deployed: http://localhost:${DEPLOYED_PORT} (kubectl port-forward)"
echo "    Keycloak: ${KEYCLOAK_URL}"
echo ""
echo "  To access deployed app:"
echo "    kubectl port-forward -n keycloak svc/fastapi-app ${DEPLOYED_PORT}:8000"
