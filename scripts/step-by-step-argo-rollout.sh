#!/usr/bin/env bash
# step-by-step-argo-rollout.sh — Single-shot Argo Rollouts integration test
#
# Covers the full lifecycle:
#   Phase 0  — Infrastructure readiness (ArgoCD, Argo Rollouts, registry)
#   Phase 1  — Dev deployment  (canary rollout → E2E tests)
#   Phase 2  — PR Preview      (ephemeral env via ArgoCD PullRequest Generator → E2E → merge)
#   Phase 3  — Prod promotion  (promote dev image → canary rollout → E2E)
#   Phase 4  — Validation      (rollout history, ArgoCD health, cleanup check)
#
# Usage:
#   ./scripts/step-by-step-argo-rollout.sh [OPTIONS]
#
# Options:
#   --skip-infra        Skip Phase 0 (assume cluster + ArgoCD + Rollouts already running)
#   --skip-phase1       Skip Phase 1 dev deploy (use existing dev image tag)
#   --skip-phase2       Skip Phase 2 PR preview
#   --skip-phase3       Skip Phase 3 prod promotion
#   --pr-number N       Reuse an existing open PR instead of creating a new one
#   --dev-tag TAG       Override dev image tag (skip build, use existing tag)
#   --dry-run           Print commands without executing
#
# Prerequisites (must be done manually before running):
#   1. sudo echo '127.0.0.1 dev.student.local prod.student.local' >> /etc/hosts
#   2. sudo echo '127.0.0.1 pr-<N>.student.local' >> /etc/hosts  (check script output for N)
#   3. GITHUB_TOKEN in env or stored in k8s secret argocd/github-token
#
# The script keeps a kubectl port-forward to argocd-server alive for gRPC
# (the socat NodePort proxy handles HTTP but not HTTP/2 gRPC).

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${PROJECT_DIR}/test-results"
LOG_FILE="${LOG_DIR}/argo-rollout-test-$(date +%Y%m%d-%H%M%S).log"

REGISTRY="localhost:5001"
GITHUB_REPO="a2z-ice/first-api-keycloak"
KEYCLOAK_URL="https://idp.keycloak.com:31111"
KEYCLOAK_REALM="student-mgmt"
ARGOCD_PF_PORT="18080"          # port-forward port (bypasses socat gRPC issue)
ARGOCD_NAMESPACE="argocd"
ROLLOUTS_VERSION="v1.8.4"

# Flags
SKIP_INFRA=false
SKIP_PHASE1=false
SKIP_PHASE2=false
SKIP_PHASE3=false
PR_NUMBER=""
DEV_TAG_OVERRIDE=""
DRY_RUN=false
PF_PID=""

# ──────────────────────────────────────────────────────────────────────────────
# Colours
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_step()    { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}"; }
log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*" >&2; }

run() {
  if $DRY_RUN; then
    echo -e "${YELLOW}[dry-run]${NC} $*"
  else
    "$@"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-infra)   SKIP_INFRA=true ;;
      --skip-phase1)  SKIP_PHASE1=true ;;
      --skip-phase2)  SKIP_PHASE2=true ;;
      --skip-phase3)  SKIP_PHASE3=true ;;
      --pr-number)    PR_NUMBER="$2"; shift ;;
      --dev-tag)      DEV_TAG_OVERRIDE="$2"; shift ;;
      --dry-run)      DRY_RUN=true ;;
      -h|--help)
        sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -20
        exit 0 ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
    shift
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup trap
# ──────────────────────────────────────────────────────────────────────────────
cleanup() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    log_info "Stopping ArgoCD port-forward (pid $PF_PID)..."
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || { log_error "Required command not found: $cmd"; exit 1; }
  done
}

setup_argocd_pf() {
  log_info "Starting kubectl port-forward argocd-server → localhost:${ARGOCD_PF_PORT}..."
  # Kill any existing port-forward on this port
  lsof -ti tcp:"${ARGOCD_PF_PORT}" | xargs kill -9 2>/dev/null || true
  kubectl port-forward svc/argocd-server -n "${ARGOCD_NAMESPACE}" \
    "${ARGOCD_PF_PORT}:80" &>/tmp/argocd-pf-${ARGOCD_PF_PORT}.log &
  PF_PID=$!
  sleep 3
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    log_error "Port-forward failed. Check /tmp/argocd-pf-${ARGOCD_PF_PORT}.log"
    exit 1
  fi

  local password
  password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d)
  argocd login "localhost:${ARGOCD_PF_PORT}" \
    --username admin --password "$password" --insecure &>/dev/null
  log_success "ArgoCD CLI logged in via port-forward localhost:${ARGOCD_PF_PORT}"
}

wait_for_pods() {
  local NS="$1" LABEL="$2" TIMEOUT="${3:-180}"
  log_info "Waiting for pods (ns=$NS, label=$LABEL, timeout=${TIMEOUT}s)..."
  local deadline=$(( $(date +%s) + TIMEOUT ))
  until kubectl get pods -n "$NS" -l "$LABEL" --no-headers 2>/dev/null | grep -q Running; do
    if [[ $(date +%s) -gt $deadline ]]; then
      log_error "Timeout waiting for pods in $NS with label $LABEL"
      kubectl get pods -n "$NS"
      exit 1
    fi
    sleep 5
  done
  log_success "Pods running in $NS (label=$LABEL)"
}

copy_tls_secret() {
  local NS="$1"
  if kubectl get secret keycloak-tls -n "$NS" &>/dev/null; then
    log_info "keycloak-tls already in $NS"
  else
    kubectl get secret keycloak-tls -n keycloak -o yaml \
      | sed "s/namespace: keycloak/namespace: ${NS}/" \
      | kubectl apply -f -
    log_success "keycloak-tls copied to $NS"
  fi
}

get_keycloak_token() {
  curl -sf --insecure \
    -d 'client_id=admin-cli' -d 'username=admin' \
    -d 'password=admin' -d 'grant_type=password' \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

get_github_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "$GITHUB_TOKEN"
  else
    kubectl get secret github-token -n "${ARGOCD_NAMESPACE}" \
      -o jsonpath='{.data.token}' | base64 -d
  fi
}

seed_database() {
  local NS="$1"
  log_info "Seeding database in $NS..."
  local TOKEN KC_ID POD
  TOKEN=$(get_keycloak_token)
  KC_ID=$(curl -sf --insecure \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?username=student-user&exact=true" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  POD=$(kubectl get pod -n "$NS" -l app=fastapi-app \
    -o jsonpath='{.items[0].metadata.name}')

  python3 - <<PYEOF | kubectl exec -n "$NS" -i "$POD" -- python3 -
import sys; sys.path.insert(0, '/app')
from app.database import SessionLocal
from app.models import Student, Department
db = SessionLocal()
for name, desc in [('Computer Science','CS'),('Mathematics','Math'),('Physics','Physics')]:
    if not db.query(Department).filter(Department.name==name).first():
        db.add(Department(name=name, description=desc)); print('Created dept:', name)
db.commit()
cs = db.query(Department).filter(Department.name=='Computer Science').first()
kc_id = '${KC_ID}'
su = db.query(Student).filter(Student.keycloak_user_id==kc_id).first()
if not su:
    db.add(Student(name='Student User',email='student-user@example.com',keycloak_user_id=kc_id,department_id=cs.id if cs else None))
    print('Created: Student User')
elif su.name != 'Student User':
    su.name = 'Student User'; su.email = 'student-user@example.com'; print('Restored: Student User')
else: print('Exists: Student User')
os_rec = db.query(Student).filter(Student.email=='other-student@example.com').first()
if not os_rec:
    db.add(Student(name='Other Student',email='other-student@example.com',department_id=cs.id if cs else None))
    print('Created: Other Student')
elif os_rec.name != 'Other Student':
    os_rec.name='Other Student'; print('Restored: Other Student')
else: print('Exists: Other Student')
db.commit(); db.close()
PYEOF
  log_success "Database seeded in $NS"
}

run_e2e() {
  local APP_URL="$1" LABEL="$2"
  log_step "E2E Tests — $LABEL ($APP_URL)"
  cd "${PROJECT_DIR}/frontend"
  APP_URL="$APP_URL" npx playwright test --reporter=list 2>&1 | tee /tmp/e2e-${LABEL// /-}.log
  local rc=${PIPESTATUS[0]}
  cd "$PROJECT_DIR"
  if [[ $rc -eq 0 ]]; then
    local passed
    passed=$(grep -c "passed" /tmp/e2e-${LABEL// /-}.log 2>/dev/null || echo "?")
    log_success "E2E PASSED — $LABEL"
  else
    log_error "E2E FAILED — $LABEL (see /tmp/e2e-${LABEL// /-}.log)"
    exit 1
  fi
}

watch_rollout() {
  local NS="$1" NAME="$2" TIMEOUT="${3:-300}"
  log_info "Watching rollout $NAME in $NS (up to ${TIMEOUT}s)..."
  local deadline=$(( $(date +%s) + TIMEOUT ))
  while true; do
    local status
    status=$(kubectl get rollout "$NAME" -n "$NS" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    local weight
    weight=$(kubectl get rollout "$NAME" -n "$NS" \
      -o jsonpath='{.status.currentWeight}' 2>/dev/null || echo "0")
    echo -e "  ${CYAN}[rollout]${NC} $NAME/$NS — phase=${status} weight=${weight}%"
    if [[ "$status" == "Healthy" ]]; then
      log_success "Rollout $NAME/$NS completed (Healthy)"
      return 0
    fi
    if [[ $(date +%s) -gt $deadline ]]; then
      log_error "Rollout $NAME/$NS did not reach Healthy within ${TIMEOUT}s"
      kubectl describe rollout "$NAME" -n "$NS" | tail -30
      exit 1
    fi
    sleep 5
  done
}

print_rollout_summary() {
  local NS="$1"
  echo ""
  log_info "Rollout summary for namespace $NS:"
  kubectl get rollouts -n "$NS" 2>/dev/null || echo "  (no Rollout resources found)"
  echo ""
  for name in fastapi-app frontend-app; do
    if kubectl get rollout "$name" -n "$NS" &>/dev/null; then
      echo "  ── $name canary events:"
      kubectl describe rollout "$name" -n "$NS" \
        | awk '/Events:/,0' | head -20
      echo ""
    fi
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 0 — Infrastructure
# ──────────────────────────────────────────────────────────────────────────────
phase0_infra() {
  log_step "Phase 0 — Infrastructure Readiness"

  # Cluster
  kubectl cluster-info &>/dev/null || { log_error "Cluster not reachable"; exit 1; }
  log_success "Kind cluster reachable"

  # Keycloak
  curl -sf --insecure "${KEYCLOAK_URL}/realms/master" &>/dev/null \
    || { log_error "Keycloak not reachable at ${KEYCLOAK_URL}"; exit 1; }
  log_success "Keycloak reachable"

  # Registry
  curl -sf "http://${REGISTRY}/v2/_catalog" &>/dev/null \
    || { log_error "Registry not reachable at ${REGISTRY}"; exit 1; }
  log_success "Registry reachable at ${REGISTRY}"

  # Argo Rollouts controller
  if ! kubectl get pods -n argo-rollouts -l app.kubernetes.io/name=argo-rollouts \
      --no-headers 2>/dev/null | grep -q Running; then
    log_info "Installing Argo Rollouts ${ROLLOUTS_VERSION}..."
    kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argo-rollouts \
      -f "https://github.com/argoproj/argo-rollouts/releases/download/${ROLLOUTS_VERSION}/install.yaml"
    kubectl wait --namespace argo-rollouts \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/name=argo-rollouts \
      --timeout=120s
  fi
  log_success "Argo Rollouts controller running"

  # Verify Rollout CRDs
  kubectl get crd rollouts.argoproj.io &>/dev/null \
    || { log_error "Rollout CRD not found"; exit 1; }
  log_success "Rollout CRD registered"

  # ArgoCD port-forward
  setup_argocd_pf

  # ArgoCD apps
  argocd app list 2>&1 | grep -E "student-app-(dev|prod)" \
    || { log_error "ArgoCD apps not found"; exit 1; }
  log_success "ArgoCD apps confirmed"

  # /etc/hosts check
  for host in dev.student.local prod.student.local; do
    if ! grep -q "$host" /etc/hosts; then
      log_error "/etc/hosts missing: $host"
      log_error "Add manually: sudo sh -c \"echo '127.0.0.1 $host' >> /etc/hosts\""
      exit 1
    fi
  done
  log_success "/etc/hosts entries present"

  # Remove old Deployment resources if they exist (migration to Rollout)
  for NS in student-app-dev student-app-prod; do
    for RES in fastapi-app frontend-app; do
      if kubectl get deployment "$RES" -n "$NS" &>/dev/null; then
        log_warn "Deleting old Deployment $RES in $NS (migrating to Rollout)..."
        kubectl delete deployment "$RES" -n "$NS"
        kubectl delete replicasets -n "$NS" -l app="$RES" 2>/dev/null || true
      fi
    done
  done

  log_success "Phase 0 complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 1 — Dev Deployment with Canary Rollout
# ──────────────────────────────────────────────────────────────────────────────
phase1_dev() {
  log_step "Phase 1 — Dev Deployment (Canary Rollout → E2E)"

  # Determine image tag
  local DEV_TAG
  if [[ -n "${DEV_TAG_OVERRIDE:-}" ]]; then
    DEV_TAG="$DEV_TAG_OVERRIDE"
    log_info "Using provided dev tag: $DEV_TAG"
  else
    local SHORT_SHA
    SHORT_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD | cut -c1-8)
    DEV_TAG="dev-${SHORT_SHA}"
    log_info "Building dev images (tag: $DEV_TAG)..."

    local FASTAPI_IMAGE="${REGISTRY}/fastapi-student-app:${DEV_TAG}"
    local FRONTEND_IMAGE="${REGISTRY}/frontend-student-app:${DEV_TAG}"

    docker build -t "$FASTAPI_IMAGE" "${PROJECT_DIR}/backend"
    docker push "$FASTAPI_IMAGE"
    docker build -t "$FRONTEND_IMAGE" "${PROJECT_DIR}/frontend"
    docker push "$FRONTEND_IMAGE"
    log_success "Images pushed: $DEV_TAG"
  fi

  # Update dev overlay kustomization.yaml
  log_info "Updating dev overlay with tag $DEV_TAG..."
  local KUST="${PROJECT_DIR}/gitops/environments/overlays/dev/kustomization.yaml"
  sed -i '' "s|newTag:.*|newTag: ${DEV_TAG}|g" "$KUST"

  # Commit and push to dev branch
  git -C "$PROJECT_DIR" add "$KUST"
  git -C "$PROJECT_DIR" commit -m "ci: deploy dev-${DEV_TAG}" --allow-empty
  git -C "$PROJECT_DIR" push origin HEAD:dev
  log_success "Dev overlay committed and pushed"

  # Wait for ArgoCD to sync
  log_info "Waiting for ArgoCD to sync student-app-dev..."
  argocd app wait student-app-dev --health --sync --timeout 300 \
    --server "localhost:${ARGOCD_PF_PORT}" --insecure
  log_success "ArgoCD student-app-dev: Synced + Healthy"

  # Show canary summary
  print_rollout_summary student-app-dev

  # Seed database
  wait_for_pods student-app-dev "app=fastapi-app" 120
  seed_database student-app-dev

  # E2E tests
  run_e2e "http://dev.student.local:8080" "dev"

  log_success "Phase 1 complete — dev canary rollout + E2E passed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 2 — PR Preview (Ephemeral Environment)
# ──────────────────────────────────────────────────────────────────────────────
phase2_pr_preview() {
  log_step "Phase 2 — PR Preview (Ephemeral Canary Env)"

  local GH_TOKEN
  GH_TOKEN=$(get_github_token)

  # Use existing PR or create a new one
  local PR_NUM
  if [[ -n "${PR_NUMBER:-}" ]]; then
    PR_NUM="$PR_NUMBER"
    log_info "Reusing existing PR #${PR_NUM}"
  else
    log_info "Creating PR preview branch..."
    local PREVIEW_BRANCH="preview/argo-rollout-test-$(date +%s)"
    git -C "$PROJECT_DIR" checkout -b "$PREVIEW_BRANCH" &>/dev/null
    git -C "$PROJECT_DIR" commit --allow-empty -m "test: trigger PR preview"
    git -C "$PROJECT_DIR" push origin "$PREVIEW_BRANCH"

    PR_NUM=$(GH_TOKEN="$GH_TOKEN" gh pr create \
      --repo "$GITHUB_REPO" \
      --title "test: Argo Rollouts PR preview" \
      --body "Automated PR preview test for Argo Rollouts canary integration." \
      --base main \
      --head "$PREVIEW_BRANCH" \
      | grep -oE '[0-9]+$')
    git -C "$PROJECT_DIR" checkout - &>/dev/null

    log_success "PR #${PR_NUM} created"
  fi

  local PR_NS="student-app-pr-${PR_NUM}"
  local PR_HOST="pr-${PR_NUM}.student.local"
  local APP_URL="http://${PR_HOST}:8080"
  local ARGOCD_APP="student-app-pr-${PR_NUM}"
  local SHORT_SHA
  SHORT_SHA=$(GH_TOKEN="$GH_TOKEN" gh pr view "$PR_NUM" --repo "$GITHUB_REPO" \
    --json headRefOid --jq '.headRefOid[:8]')
  local FASTAPI_IMAGE="${REGISTRY}/fastapi-student-app:pr-${PR_NUM}-${SHORT_SHA}"
  local FRONTEND_IMAGE="${REGISTRY}/frontend-student-app:pr-${PR_NUM}-${SHORT_SHA}"

  # Check /etc/hosts
  if ! grep -q "$PR_HOST" /etc/hosts; then
    log_error "/etc/hosts missing entry for ${PR_HOST}"
    log_error "Add manually: sudo sh -c \"echo '127.0.0.1 ${PR_HOST}' >> /etc/hosts\""
    exit 1
  fi

  # Build + push PR images
  log_info "Building PR images (tag pr-${PR_NUM}-${SHORT_SHA})..."
  docker build -t "$FASTAPI_IMAGE" "${PROJECT_DIR}/backend"
  docker push "$FASTAPI_IMAGE"
  docker build -t "$FRONTEND_IMAGE" "${PROJECT_DIR}/frontend"
  docker push "$FRONTEND_IMAGE"
  log_success "PR images pushed"

  # Label PR to trigger ArgoCD PullRequest Generator
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"labels":["preview"]}' \
    "https://api.github.com/repos/${GITHUB_REPO}/issues/${PR_NUM}/labels" &>/dev/null
  log_success "Label 'preview' added to PR #${PR_NUM}"

  # Register Keycloak client for PR
  local KC_CLIENT_ID="student-app-pr-${PR_NUM}"
  local KC_CLIENT_SECRET="student-app-pr-${PR_NUM}-secret"
  log_info "Registering Keycloak client for PR preview..."
  local TOKEN
  TOKEN=$(get_keycloak_token)
  curl -sf --insecure -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"${KC_CLIENT_ID}\",
      \"enabled\": true,
      \"protocol\": \"openid-connect\",
      \"publicClient\": false,
      \"secret\": \"${KC_CLIENT_SECRET}\",
      \"redirectUris\": [\"${APP_URL}/api/auth/callback\"],
      \"webOrigins\": [\"${APP_URL}\"],
      \"standardFlowEnabled\": true,
      \"directAccessGrantsEnabled\": false,
      \"attributes\": {\"pkce.code.challenge.method\": \"S256\"}
    }" \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" &>/dev/null \
    && log_success "Keycloak client created" \
    || log_warn "Keycloak client may already exist, continuing"

  # Wait for ArgoCD to create the namespace and PR app
  log_info "Waiting for ArgoCD to create $PR_NS namespace (up to 120s)..."
  local count=0
  until kubectl get namespace "$PR_NS" &>/dev/null; do
    count=$(( count + 1 ))
    if [[ $count -ge 24 ]]; then
      log_error "Namespace $PR_NS not created — ArgoCD may not have polled GitHub yet"
      exit 1
    fi
    echo "  waiting... (${count}/24)"
    sleep 5
  done
  log_success "Namespace $PR_NS created"

  # Copy TLS secret
  copy_tls_secret "$PR_NS"

  # Wait for ArgoCD app to be healthy (includes canary steps)
  log_info "Waiting for ArgoCD app $ARGOCD_APP (canary rollout, up to 300s)..."
  argocd app wait "$ARGOCD_APP" --health --sync --timeout 300 \
    --server "localhost:${ARGOCD_PF_PORT}" --insecure
  log_success "ArgoCD $ARGOCD_APP: Synced + Healthy"

  # Show canary summary
  print_rollout_summary "$PR_NS"

  # Seed
  wait_for_pods "$PR_NS" "app=fastapi-app" 120
  seed_database "$PR_NS"

  # E2E
  run_e2e "$APP_URL" "pr-preview-${PR_NUM}"

  log_success "Phase 2 E2E passed — merging PR #${PR_NUM}..."
  GH_TOKEN="$GH_TOKEN" gh pr merge "$PR_NUM" \
    --repo "$GITHUB_REPO" --merge --admin
  log_success "PR #${PR_NUM} merged — ArgoCD will cascade-delete $PR_NS"

  # Cleanup Keycloak client
  TOKEN=$(get_keycloak_token)
  local CLIENT_UUID
  CLIENT_UUID=$(curl -sf --insecure \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KC_CLIENT_ID}" \
    | python3 -c "import sys,json; c=json.load(sys.stdin); print(c[0]['id'] if c else '')")
  if [[ -n "$CLIENT_UUID" ]]; then
    curl -sf --insecure -X DELETE \
      -H "Authorization: Bearer ${TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}" \
      && log_success "Keycloak client ${KC_CLIENT_ID} deleted"
  fi

  # Wait for namespace deletion (cascade prune)
  log_info "Waiting for ArgoCD cascade-prune of $PR_NS (up to 60s)..."
  local i=0
  while kubectl get namespace "$PR_NS" &>/dev/null; do
    i=$(( i + 1 ))
    if [[ $i -ge 12 ]]; then log_warn "$PR_NS still exists — prune may be delayed"; break; fi
    sleep 5
  done
  kubectl get namespace "$PR_NS" &>/dev/null \
    && log_warn "$PR_NS still exists (ArgoCD prune may be in progress)" \
    || log_success "$PR_NS deleted (cascade prune complete)"

  log_success "Phase 2 complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 3 — Prod Promotion
# ──────────────────────────────────────────────────────────────────────────────
phase3_prod() {
  log_step "Phase 3 — Prod Promotion (reuse dev image → Canary → E2E)"

  # Read current dev tag from dev overlay
  local KUST_DEV="${PROJECT_DIR}/gitops/environments/overlays/dev/kustomization.yaml"
  local DEV_TAG
  DEV_TAG=$(grep "newTag:" "$KUST_DEV" | awk '{print $2}' | head -1)
  log_info "Promoting dev tag → prod: $DEV_TAG"

  # Update prod overlay
  local KUST_PROD="${PROJECT_DIR}/gitops/environments/overlays/prod/kustomization.yaml"
  sed -i '' "s|newTag:.*|newTag: ${DEV_TAG}|g" "$KUST_PROD"
  git -C "$PROJECT_DIR" add "$KUST_PROD"
  git -C "$PROJECT_DIR" commit -m "ci: promote ${DEV_TAG} to prod" --allow-empty
  git -C "$PROJECT_DIR" push origin HEAD:main
  log_success "Prod overlay updated and pushed to main"

  # Wait for ArgoCD sync
  log_info "Waiting for ArgoCD to sync student-app-prod..."
  argocd app wait student-app-prod --health --sync --timeout 300 \
    --server "localhost:${ARGOCD_PF_PORT}" --insecure
  log_success "ArgoCD student-app-prod: Synced + Healthy"

  # Show canary summary
  print_rollout_summary student-app-prod

  # Seed
  wait_for_pods student-app-prod "app=fastapi-app" 120
  seed_database student-app-prod

  # E2E
  run_e2e "http://prod.student.local:8080" "prod"

  log_success "Phase 3 complete — prod promoted with canary rollout + E2E passed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 4 — Validation
# ──────────────────────────────────────────────────────────────────────────────
phase4_validate() {
  log_step "Phase 4 — Validation & Summary"

  echo ""
  log_info "=== ArgoCD Application Status ==="
  argocd app list --server "localhost:${ARGOCD_PF_PORT}" --insecure 2>&1 \
    | grep -E "NAME|student-app"

  echo ""
  log_info "=== Argo Rollouts Controller ==="
  kubectl get pods -n argo-rollouts

  echo ""
  log_info "=== Dev Rollouts ==="
  kubectl get rollouts -n student-app-dev 2>/dev/null \
    || echo "  (no rollouts — namespace may be empty)"

  echo ""
  log_info "=== Prod Rollouts ==="
  kubectl get rollouts -n student-app-prod 2>/dev/null \
    || echo "  (no rollouts — namespace may be empty)"

  echo ""
  log_info "=== Rollout History (fastapi-app dev) ==="
  kubectl rollout history rollout/fastapi-app -n student-app-dev 2>/dev/null \
    || echo "  (not available)"

  echo ""
  log_info "=== Rollout CRDs registered ==="
  kubectl get crd | grep argoproj.io | awk '{print "  "$1}'

  echo ""
  log_info "=== ArgoCD Version ==="
  argocd version --server "localhost:${ARGOCD_PF_PORT}" --insecure 2>&1 | head -2

  echo ""
  log_success "Phase 4 validation complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  mkdir -p "$LOG_DIR"
  exec > >(tee "$LOG_FILE") 2>&1

  echo -e "${BOLD}${GREEN}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║        Argo Rollouts Integration Test — Full Pipeline        ║"
  echo "║  ArgoCD v3.3.1 + Argo Rollouts v1.8.4 + Canary Strategy     ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo "  Started:    $(date)"
  echo "  Log file:   $LOG_FILE"
  echo "  Project:    $PROJECT_DIR"
  echo ""

  require_cmd kubectl argocd docker git curl python3 npx

  $SKIP_INFRA || phase0_infra

  # If skipping phase0 but ArgoCD PF not set up yet, do it now
  if $SKIP_INFRA && [[ -z "${PF_PID:-}" ]]; then
    setup_argocd_pf
  fi

  $SKIP_PHASE1 || phase1_dev
  $SKIP_PHASE2 || phase2_pr_preview
  $SKIP_PHASE3 || phase3_prod
  phase4_validate

  echo ""
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${GREEN}  ALL PHASES PASSED  ✓${NC}"
  echo -e "${BOLD}${GREEN}  Completed: $(date)${NC}"
  echo -e "${BOLD}${GREEN}  Full log:  $LOG_FILE${NC}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main "$@"
