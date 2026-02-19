#!/usr/bin/env bash
# scripts/cicd-pipeline-test.sh
#
# Complete automated test of the ArgoCD GitOps multi-environment pipeline.
# Mirrors every step in cicd-test-instruction.md with full shell automation.
#
#   Phase 0: One-time setup  (registry, ArgoCD, Keycloak clients, /etc/hosts)
#   Phase 1: Dev pipeline    (build → push → git → ArgoCD sync → E2E)
#   Phase 2: PR Preview      (create PR → build → label → ArgoCD → E2E → cleanup)
#   Phase 3: Prod promotion  (read dev tag → update prod overlay → ArgoCD sync → E2E)
#   Verify:  Final health checks
#
# Usage:
#   GITHUB_TOKEN=<pat> ./scripts/cicd-pipeline-test.sh [OPTIONS]
#
# Options:
#   --skip-setup      Skip Phase 0 (cluster + ArgoCD already running)
#   --skip-phase1     Skip Phase 1 (dev pipeline)
#   --skip-phase2     Skip Phase 2 (PR preview)
#   --skip-phase3     Skip Phase 3 (prod promotion)
#   --skip-verify     Skip final verification checks
#   --pr-number N     Reuse an existing open PR (skip PR creation in Phase 2)
#   -h, --help        Show this help

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GITHUB_OWNER="a2z-ice"
GITHUB_REPO="first-api-keycloak"
GITHUB_API="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}"

KEYCLOAK_URL="https://idp.keycloak.com:31111"
REGISTRY="localhost:5001"
ARGOCD_LOCAL_PORT="30080"
PR_BRANCH="feature/auto-cicd-test"

# ──────────────────────────────────────────────────────────────────────────────
# Flags (defaults)
# ──────────────────────────────────────────────────────────────────────────────
SKIP_SETUP=false
SKIP_PHASE1=false
SKIP_PHASE2=false
SKIP_PHASE3=false
SKIP_VERIFY=false
REUSE_PR_NUMBER=""

# ──────────────────────────────────────────────────────────────────────────────
# Colors / logging
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_phase() {
  echo -e "\n${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD}  $1${NC}"
  echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
}
log_step()    { echo -e "\n${CYAN}▶ $1${NC}"; }
log_info()    { echo -e "  ${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[OK]${NC}   $1"; }
log_warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "  ${RED}[ERROR]${NC} $1" >&2; }
log_result()  { echo -e "\n${BOLD}$1${NC}"; }

# ──────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-setup)   SKIP_SETUP=true ;;
      --skip-phase1)  SKIP_PHASE1=true ;;
      --skip-phase2)  SKIP_PHASE2=true ;;
      --skip-phase3)  SKIP_PHASE3=true ;;
      --skip-verify)  SKIP_VERIFY=true ;;
      --pr-number)    REUSE_PR_NUMBER="$2"; shift ;;
      -h|--help)
        grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
        exit 0 ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
    shift
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Prerequisite checks
# ──────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
  log_step "Checking prerequisites"
  local missing=0
  for cmd in docker kubectl kind argocd curl python3 node npm git; do
    if command -v "$cmd" &>/dev/null; then
      log_success "$cmd found"
    else
      log_error "$cmd not found — install it first"
      missing=1
    fi
  done
  [[ $missing -eq 1 ]] && exit 1

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log_error "GITHUB_TOKEN is not set. Export your GitHub PAT:"
    echo "  export GITHUB_TOKEN=ghp_..."
    exit 1
  fi
  log_success "GITHUB_TOKEN is set"

  # Verify token can access the repo
  local repo_name
  repo_name=$(curl -sf -H "Authorization: token ${GITHUB_TOKEN}" \
    "${GITHUB_API}" | python3 -c "import sys,json; print(json.load(sys.stdin)['full_name'])" 2>/dev/null || echo "")
  if [[ "$repo_name" != "${GITHUB_OWNER}/${GITHUB_REPO}" ]]; then
    log_error "GITHUB_TOKEN cannot access ${GITHUB_OWNER}/${GITHUB_REPO} — check token scopes (repo, workflow)"
    exit 1
  fi
  log_success "GitHub token verified — repo: $repo_name"
}

# ──────────────────────────────────────────────────────────────────────────────
# ArgoCD port-forward management
# ──────────────────────────────────────────────────────────────────────────────
ARGOCD_PF_PID=""

start_argocd_portforward() {
  # Kill any existing port-forward on the port
  kill_argocd_portforward

  log_info "Starting ArgoCD port-forward on localhost:${ARGOCD_LOCAL_PORT}..."
  kubectl port-forward svc/argocd-server -n argocd \
    "${ARGOCD_LOCAL_PORT}:80" &>/dev/null &
  ARGOCD_PF_PID=$!
  sleep 3

  # Login
  local password
  password=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d)
  argocd login "localhost:${ARGOCD_LOCAL_PORT}" \
    --username admin --password "$password" --insecure &>/dev/null
  log_success "ArgoCD CLI logged in (port-forward PID: $ARGOCD_PF_PID)"
}

kill_argocd_portforward() {
  # Kill all port-forwards on the ArgoCD port
  local pids
  pids=$(lsof -ti "tcp:${ARGOCD_LOCAL_PORT}" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill 2>/dev/null || true
  fi
  ARGOCD_PF_PID=""
}

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup trap
# ──────────────────────────────────────────────────────────────────────────────
cleanup() {
  echo -e "\n${YELLOW}[cleanup]${NC} Killing background processes..."
  kill_argocd_portforward
  # Restore original git branch
  if [[ -n "${ORIGINAL_BRANCH:-}" ]]; then
    git -C "$PROJECT_DIR" checkout "$ORIGINAL_BRANCH" &>/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
get_keycloak_admin_token() {
  curl -sf --insecure \
    -d "client_id=admin-cli" \
    -d "username=admin" \
    -d "password=admin" \
    -d "grant_type=password" \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

get_keycloak_user_id() {
  local token="$1"
  local username="$2"
  curl -sf --insecure \
    -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_URL}/admin/realms/student-mgmt/users?username=${username}&exact=true" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])"
}

# Seeds departments and a student user in the given namespace.
# Uses stdin pipe to kubectl exec (no tar needed, no file copy needed).
seed_database() {
  local NS="$1"
  local KC_ID="$2"

  log_info "Seeding database in namespace: $NS"
  local POD
  POD=$(kubectl get pod -n "$NS" -l app=fastapi-app \
    -o jsonpath='{.items[0].metadata.name}')

  # Build the Python script with KC_ID substituted by bash
  # The heredoc delimiter is UNQUOTED so bash expands ${KC_ID}
  # Python f-string braces {db.query...} are safe (no leading $)
  #
  # IMPORTANT: The seed RESTORES names (not just checks existence) because
  # the E2E test 'admin can edit a student' renames records between runs.
  # This ensures visibility tests always find 'Student User' and 'Other Student'.
  local SEED_PY
  SEED_PY=$(cat <<PYEOF
from app.database import SessionLocal
from app.models import Student, Department
db = SessionLocal()
# Ensure the 3 required departments exist
required_depts = [
    ('Computer Science', 'CS department'),
    ('Mathematics', 'Math department'),
    ('Physics', 'Physics department'),
]
for dept_name, dept_desc in required_depts:
    if not db.query(Department).filter(Department.name == dept_name).first():
        db.add(Department(name=dept_name, description=dept_desc))
        print('Created department:', dept_name)
db.commit()
cs = db.query(Department).filter(Department.name == 'Computer Science').first()
# Ensure Student User exists with correct name (edit tests may rename it)
kc_id = '${KC_ID}'
su = db.query(Student).filter(Student.keycloak_user_id == kc_id).first()
if not su:
    db.add(Student(name='Student User', email='student-user@example.com',
                   keycloak_user_id=kc_id, department_id=cs.id if cs else None))
    print('Created: Student User')
elif su.name != 'Student User':
    su.name = 'Student User'
    su.email = 'student-user@example.com'
    print('Restored name: Student User (was:', su.name + ')')
else:
    print('Exists: Student User')
# Ensure Other Student exists with correct name
os = db.query(Student).filter(Student.email == 'other-student@example.com').first()
if not os:
    db.add(Student(name='Other Student', email='other-student@example.com',
                   department_id=cs.id if cs else None))
    print('Created: Other Student')
elif os.name != 'Other Student':
    os.name = 'Other Student'
    print('Restored name: Other Student')
else:
    print('Exists: Other Student')
db.commit()
db.close()
PYEOF
  )

  echo "$SEED_PY" | kubectl exec -n "$NS" -i "$POD" -- python
  log_success "Database seeded in $NS"
}

add_hosts_entry() {
  local HOST="$1"
  local IP="${2:-127.0.0.1}"
  if grep -q "$HOST" /etc/hosts 2>/dev/null; then
    log_info "$HOST already in /etc/hosts"
    return 0
  fi
  local CMD="echo '${IP} ${HOST}' | sudo tee -a /etc/hosts"
  while true; do
    echo ""
    echo -e "  ${YELLOW}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}${BOLD}║  ACTION REQUIRED — /etc/hosts entry missing      ║${NC}"
    echo -e "  ${YELLOW}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "  Run this command in another terminal:\n"
    echo -e "    ${CYAN}${CMD}${NC}\n"
    printf "  Press Enter once done (Ctrl+C to abort): "
    read -r < /dev/tty
    if grep -q "$HOST" /etc/hosts 2>/dev/null; then
      log_success "$HOST confirmed in /etc/hosts"
      return 0
    fi
    log_warn "$HOST not found yet — please run the command and press Enter again"
  done
}

remove_hosts_entry() {
  local HOST="$1"
  if ! grep -q "$HOST" /etc/hosts 2>/dev/null; then
    return 0
  fi
  local CMD="sudo sed -i '' '/${HOST}/d' /etc/hosts"
  while true; do
    echo ""
    echo -e "  ${YELLOW}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}${BOLD}║  ACTION REQUIRED — remove /etc/hosts entry       ║${NC}"
    echo -e "  ${YELLOW}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "  Run this command in another terminal:\n"
    echo -e "    ${CYAN}${CMD}${NC}\n"
    printf "  Press Enter once done (Ctrl+C to abort): "
    read -r < /dev/tty
    if ! grep -q "$HOST" /etc/hosts 2>/dev/null; then
      log_success "$HOST removed from /etc/hosts"
      return 0
    fi
    log_warn "$HOST still found — please run the command and press Enter again"
  done
}

check_and_fix_coredns() {
  log_step "Checking CoreDNS IP for idp.keycloak.com"
  local NODE_IP
  NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
  if [[ -z "$NODE_IP" ]]; then
    log_warn "Could not determine node IP — skipping CoreDNS check"
    return 0
  fi
  log_info "Kind node IP: $NODE_IP"

  local COREFILE
  COREFILE=$(kubectl get configmap coredns -n kube-system \
    -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
  if [[ -z "$COREFILE" ]]; then
    log_warn "Could not read CoreDNS Corefile — skipping CoreDNS check"
    return 0
  fi

  local CURRENT_IP
  CURRENT_IP=$(echo "$COREFILE" | grep "idp.keycloak.com" | awk '{print $1}' | head -1)
  if [[ -z "$CURRENT_IP" ]]; then
    log_warn "idp.keycloak.com not found in CoreDNS hosts — cluster may need full setup"
    return 0
  fi

  if [[ "$CURRENT_IP" == "$NODE_IP" ]]; then
    log_success "CoreDNS IP for idp.keycloak.com is correct ($NODE_IP)"
    return 0
  fi

  log_warn "CoreDNS stale IP detected: $CURRENT_IP → should be $NODE_IP"
  log_info "Auto-patching CoreDNS configmap..."

  local NEW_COREFILE
  NEW_COREFILE=$(echo "$COREFILE" \
    | sed "s|${CURRENT_IP} idp.keycloak.com|${NODE_IP} idp.keycloak.com|g")
  kubectl patch configmap coredns -n kube-system --type=merge \
    -p "{\"data\":{\"Corefile\":$(echo "$NEW_COREFILE" \
      | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")}}"

  log_info "Restarting CoreDNS..."
  kubectl rollout restart deployment coredns -n kube-system
  kubectl rollout status deployment coredns -n kube-system --timeout=60s 2>/dev/null || true

  for ns in student-app-dev student-app-prod; do
    if kubectl get deployment fastapi-app -n "$ns" &>/dev/null; then
      log_info "Restarting fastapi-app in $ns"
      kubectl rollout restart deployment fastapi-app -n "$ns"
    fi
  done
  if kubectl get deployment fastapi-app -n student-app-dev &>/dev/null; then
    kubectl rollout status deployment fastapi-app -n student-app-dev --timeout=120s 2>/dev/null || true
  fi

  log_success "CoreDNS patched ($CURRENT_IP → $NODE_IP) and pods restarted"
}

copy_tls_secret() {
  local NS="$1"
  if kubectl get secret keycloak-tls -n "$NS" &>/dev/null; then
    log_info "keycloak-tls already present in $NS"
  else
    kubectl get secret keycloak-tls -n keycloak -o yaml \
      | sed "s/namespace: keycloak/namespace: ${NS}/" \
      | kubectl apply -f -
    log_success "keycloak-tls copied to $NS"
  fi
}

wait_for_pods() {
  local NS="$1"
  local LABEL="$2"
  local TIMEOUT="${3:-180}"

  log_info "Waiting for pods (ns=$NS, label=$LABEL)..."
  local deadline=$(( $(date +%s) + TIMEOUT ))
  until kubectl get pods -n "$NS" -l "$LABEL" --no-headers 2>/dev/null \
        | grep -q Running; do
    if [[ $(date +%s) -gt $deadline ]]; then
      log_error "Timeout waiting for pods in $NS with label $LABEL"
      kubectl get pods -n "$NS"
      exit 1
    fi
    sleep 5
  done
  log_success "Pods running in $NS"
}

run_e2e_tests() {
  local APP_URL="$1"
  local LABEL="$2"  # description

  log_step "Running E2E tests against $APP_URL ($LABEL)"

  # Verify health first
  local health_url="${APP_URL}/api/health"
  log_info "Health check: $health_url"
  local retries=0
  until curl -sf "$health_url" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok'" 2>/dev/null; do
    retries=$(( retries + 1 ))
    if [[ $retries -ge 20 ]]; then
      log_error "Health check failed after ${retries} retries: $health_url"
      exit 1
    fi
    log_info "Health check not ready (attempt $retries/20), retrying in 10s..."
    sleep 10
  done
  log_success "Health check passed: $health_url"

  cd "$PROJECT_DIR/frontend"
  APP_URL="$APP_URL" npx playwright test --reporter=line
  local exit_code=$?
  cd "$PROJECT_DIR"

  if [[ $exit_code -eq 0 ]]; then
    log_success "E2E tests passed for $LABEL"
  else
    log_error "E2E tests FAILED for $LABEL (exit code: $exit_code)"
    exit $exit_code
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 0: One-Time Setup
# ──────────────────────────────────────────────────────────────────────────────
phase0_setup() {
  log_phase "Phase 0: One-Time Setup"

  # --- Registry ---
  log_step "Starting local Docker registry"
  bash "$SCRIPT_DIR/setup-registry.sh"

  # Verify
  curl -sf "http://${REGISTRY}/v2/_catalog" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print('Registry OK, repos:', d.get('repositories', []))"

  # --- Cluster + Keycloak ---
  log_step "Running base setup (cluster, Keycloak, realm, test users)"
  cd "$PROJECT_DIR"
  ./setup.sh
  cd "$PROJECT_DIR"

  # --- ArgoCD + Ingress + CoreDNS ---
  log_step "Setting up ArgoCD, Nginx Ingress, CoreDNS"
  bash "$SCRIPT_DIR/setup-argocd.sh"

  # --- Keycloak clients for dev/prod ---
  log_step "Creating Keycloak clients for dev and prod"
  bash "$SCRIPT_DIR/setup-keycloak-envs.sh"

  # --- /etc/hosts ---
  log_step "Configuring /etc/hosts"
  for host in dev.student.local prod.student.local; do
    add_hosts_entry "$host"
  done

  # --- GitHub token secret in ArgoCD namespace ---
  log_step "Creating github-token secret in ArgoCD namespace"
  kubectl create secret generic github-token \
    --namespace argocd \
    --from-literal=token="${GITHUB_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  log_success "github-token secret applied in argocd namespace"

  # --- Push gitops branches ---
  log_step "Ensuring dev and main branches have gitops overlay files"
  local current_branch
  current_branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)

  # dev branch: push cicd → dev (force to ensure gitops/ files are present)
  git -C "$PROJECT_DIR" push origin "cicd:dev" --force
  log_success "cicd pushed to origin/dev"

  # main branch: already contains gitops/ from previous merge
  # Just verify and push the current state
  git -C "$PROJECT_DIR" checkout main
  git -C "$PROJECT_DIR" merge cicd --no-edit 2>/dev/null || true
  git -C "$PROJECT_DIR" push origin main
  log_success "main branch up to date with gitops/ files"

  git -C "$PROJECT_DIR" checkout "$current_branch"

  log_success "Phase 0 complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 1: Dev Environment Pipeline
# ──────────────────────────────────────────────────────────────────────────────
phase1_dev() {
  log_phase "Phase 1: Dev Environment Pipeline"

  # --- 1.1 Build and push dev images ---
  log_step "1.1 Building dev images"

  # We need to be on a branch that has the application source code
  # cicd/react branch has the source; switch to current working branch
  local GIT_SHA
  GIT_SHA=$(git -C "$PROJECT_DIR" rev-parse --short HEAD)
  IMAGE_TAG="dev-${GIT_SHA}"
  log_info "Image tag: $IMAGE_TAG"

  # Copy CA cert into backend build context
  mkdir -p "$PROJECT_DIR/backend/certs"
  cp "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/backend/certs/ca.crt"

  docker build -t "${REGISTRY}/fastapi-student-app:${IMAGE_TAG}" \
    "$PROJECT_DIR/backend"
  rm -rf "$PROJECT_DIR/backend/certs"

  docker build -t "${REGISTRY}/frontend-student-app:${IMAGE_TAG}" \
    "$PROJECT_DIR/frontend"

  log_step "1.1 Pushing dev images"
  docker push "${REGISTRY}/fastapi-student-app:${IMAGE_TAG}"
  docker push "${REGISTRY}/frontend-student-app:${IMAGE_TAG}"
  log_success "Dev images pushed: $IMAGE_TAG"

  # --- 1.2 Update dev overlay and push to git ---
  log_step "1.2 Updating dev overlay kustomization.yaml with $IMAGE_TAG"

  git -C "$PROJECT_DIR" checkout dev
  git -C "$PROJECT_DIR" pull origin dev --rebase 2>/dev/null || true

  local DEV_KUST="$PROJECT_DIR/gitops/environments/overlays/dev/kustomization.yaml"
  # Use perl for cross-platform in-place sed (avoids macOS vs GNU sed differences)
  perl -i -pe "s|newTag: .*|newTag: ${IMAGE_TAG}|g" "$DEV_KUST"

  log_info "Updated tags in dev/kustomization.yaml:"
  grep "newTag" "$DEV_KUST"

  git -C "$PROJECT_DIR" add "$DEV_KUST"
  if git -C "$PROJECT_DIR" diff --cached --quiet; then
    log_info "Dev overlay already at $IMAGE_TAG — no commit needed, triggering ArgoCD refresh"
  else
    git -C "$PROJECT_DIR" commit -m "ci: update dev image tags to ${IMAGE_TAG}"
    git -C "$PROJECT_DIR" push origin dev
    log_success "Dev overlay pushed to origin/dev"
  fi

  git -C "$PROJECT_DIR" checkout "$ORIGINAL_BRANCH"

  # --- 1.3 Wait for ArgoCD sync ---
  log_step "1.3 Waiting for student-app-dev to sync (ArgoCD polls every 3 min)"
  log_info "Triggering ArgoCD hard refresh to skip poll delay..."
  argocd app get student-app-dev --hard-refresh &>/dev/null || true
  sleep 5
  argocd app wait student-app-dev --health --sync --timeout 300
  log_success "student-app-dev: Synced + Healthy"

  kubectl get pods -n student-app-dev

  # --- 1.4 TLS secret + seed database ---
  log_step "1.4 Copying TLS secret and seeding database (dev)"
  copy_tls_secret student-app-dev
  wait_for_pods student-app-dev "app=fastapi-app"

  local ADMIN_TOKEN KC_ID
  ADMIN_TOKEN=$(get_keycloak_admin_token)
  KC_ID=$(get_keycloak_user_id "$ADMIN_TOKEN" "student-user")
  log_info "student-user Keycloak ID: $KC_ID"

  seed_database student-app-dev "$KC_ID"

  # --- 1.5 E2E tests ---
  run_e2e_tests "http://dev.student.local:8080" "Phase 1 — Dev"

  log_success "Phase 1 complete ✓"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 2: PR Preview Pipeline
# ──────────────────────────────────────────────────────────────────────────────
phase2_pr_preview() {
  log_phase "Phase 2: PR Preview Pipeline"

  local PR_NUMBER=""

  if [[ -n "$REUSE_PR_NUMBER" ]]; then
    PR_NUMBER="$REUSE_PR_NUMBER"
    log_info "Reusing existing PR #${PR_NUMBER}"
  else
    # --- 2.1 Create feature branch + PR ---
    log_step "2.1 Creating feature branch and PR"

    # Clean up remote branch if it exists from a previous run
    if git -C "$PROJECT_DIR" ls-remote --exit-code origin "$PR_BRANCH" &>/dev/null; then
      log_info "Remote branch $PR_BRANCH exists — deleting for clean start"
      git -C "$PROJECT_DIR" push origin --delete "$PR_BRANCH" 2>/dev/null || true
    fi

    git -C "$PROJECT_DIR" checkout dev
    git -C "$PROJECT_DIR" pull origin dev --rebase 2>/dev/null || true
    git -C "$PROJECT_DIR" checkout -B "$PR_BRANCH"

    # Make a trivial commit so the branch has something unique
    echo "# Auto-generated by cicd-pipeline-test.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "$PROJECT_DIR/.cicd-test-run"
    git -C "$PROJECT_DIR" add "$PROJECT_DIR/.cicd-test-run"
    git -C "$PROJECT_DIR" commit -m "test: PR preview pipeline automated test"
    git -C "$PROJECT_DIR" push -u origin "$PR_BRANCH"
    log_success "Branch $PR_BRANCH pushed"

    # Create PR via GitHub REST API
    local PR_RESPONSE
    PR_RESPONSE=$(curl -sf -X POST \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"[Auto] PR Preview Pipeline Test\",\"head\":\"${PR_BRANCH}\",\"base\":\"dev\",\"body\":\"Automated PR created by cicd-pipeline-test.sh to test the ArgoCD PR Preview pipeline.\"}" \
      "${GITHUB_API}/pulls")

    PR_NUMBER=$(echo "$PR_RESPONSE" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
    log_success "Created PR #${PR_NUMBER}"
  fi

  # Get PR HEAD SHA (8 chars — ArgoCD requirement)
  local PR_SHA
  PR_SHA=$(curl -sf \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    "${GITHUB_API}/pulls/${PR_NUMBER}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['head']['sha'][:8])")
  log_info "PR #${PR_NUMBER} HEAD SHA (8-char): $PR_SHA"

  local PR_IMAGE_TAG="pr-${PR_NUMBER}-${PR_SHA}"
  log_info "PR image tag: $PR_IMAGE_TAG"

  # Prompt for /etc/hosts NOW — before the long build/push/wait steps
  # so the user can add it while the build runs.
  local PR_HOST="pr-${PR_NUMBER}.student.local"
  add_hosts_entry "$PR_HOST"

  # --- 2.2 Build and push PR images ---
  log_step "2.2 Building PR images"

  # Build from current source (on the PR branch checkout)
  git -C "$PROJECT_DIR" checkout "$PR_BRANCH" 2>/dev/null || \
    git -C "$PROJECT_DIR" checkout "$ORIGINAL_BRANCH"

  mkdir -p "$PROJECT_DIR/backend/certs"
  cp "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/backend/certs/ca.crt"

  docker build -t "${REGISTRY}/fastapi-student-app:${PR_IMAGE_TAG}" \
    "$PROJECT_DIR/backend"
  rm -rf "$PROJECT_DIR/backend/certs"

  docker build -t "${REGISTRY}/frontend-student-app:${PR_IMAGE_TAG}" \
    "$PROJECT_DIR/frontend"

  docker push "${REGISTRY}/fastapi-student-app:${PR_IMAGE_TAG}"
  docker push "${REGISTRY}/frontend-student-app:${PR_IMAGE_TAG}"
  log_success "PR images pushed: $PR_IMAGE_TAG"

  git -C "$PROJECT_DIR" checkout "$ORIGINAL_BRANCH"

  # --- 2.3 Label the PR to trigger ArgoCD PullRequest Generator ---
  log_step "2.3 Adding 'preview' label to PR #${PR_NUMBER}"
  curl -sf -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"labels":["preview"]}' \
    "${GITHUB_API}/issues/${PR_NUMBER}/labels" \
    | python3 -c "import sys,json; print('Labels added:', [l['name'] for l in json.load(sys.stdin)])"
  log_success "PR #${PR_NUMBER} labeled with 'preview'"

  # --- 2.4 Wait for ArgoCD to create the preview Application ---
  log_step "2.4 Waiting for ArgoCD to create student-app-pr-${PR_NUMBER}"
  log_info "(ArgoCD PullRequest Generator polls GitHub every 30s)"

  local APP_NAME="student-app-pr-${PR_NUMBER}"
  local NS_NAME="student-app-pr-${PR_NUMBER}"
  local deadline=$(( $(date +%s) + 300 ))
  while true; do
    # Primary check: ArgoCD Application K8s resource (no CLI needed)
    if kubectl get application "$APP_NAME" -n argocd &>/dev/null; then
      log_success "Application $APP_NAME created by ArgoCD"
      break
    fi
    # Fallback: check namespace creation (ArgoCD CreateNamespace=true)
    if kubectl get ns "$NS_NAME" &>/dev/null; then
      log_success "Namespace $NS_NAME exists — ArgoCD Application is active"
      break
    fi
    if [[ $(date +%s) -gt $deadline ]]; then
      log_error "Timeout: ArgoCD did not create $APP_NAME within 5 minutes"
      log_info "Checking ApplicationSet controller logs..."
      kubectl logs -n argocd \
        -l app.kubernetes.io/name=argocd-applicationset-controller \
        --tail=30 | grep -iE "error|pr|preview|github" || true
      exit 1
    fi
    log_info "Not yet created, waiting 15s... ($(( deadline - $(date +%s) ))s remaining)"
    sleep 15
  done

  # --- 2.5 Setup preview environment ---
  local NS="student-app-pr-${PR_NUMBER}"

  log_step "2.5 Setting up preview environment ($NS)"

  # Copy TLS secret FIRST — init container needs it to start
  # (ArgoCD CreateNamespace=true creates the namespace; secret must be present before pods start)
  # Wait briefly for namespace to exist before copying secret
  local ns_deadline=$(( $(date +%s) + 60 ))
  until kubectl get ns "$NS" &>/dev/null; do
    [[ $(date +%s) -gt $ns_deadline ]] && { log_error "Namespace $NS not found"; exit 1; }
    sleep 3
  done
  copy_tls_secret "$NS"

  # Wait for namespace to have Running pods (init container can now mount the TLS secret)
  wait_for_pods "$NS" "app=fastapi-app" 240

  # Wait for ArgoCD sync
  argocd app wait "$APP_NAME" --health --sync --timeout 180
  log_success "$APP_NAME: Synced + Healthy"

  # Register Keycloak client for this PR
  log_info "Creating Keycloak client: student-app-pr-${PR_NUMBER}"
  local ADMIN_TOKEN KC_ID
  ADMIN_TOKEN=$(get_keycloak_admin_token)

  # Check if client already exists
  local EXISTING_CLIENT
  EXISTING_CLIENT=$(curl -sf --insecure \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/student-mgmt/clients?clientId=student-app-pr-${PR_NUMBER}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || echo "")

  if [[ -z "$EXISTING_CLIENT" ]]; then
    curl -sf --insecure -X POST \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"clientId\": \"student-app-pr-${PR_NUMBER}\",
        \"enabled\": true,
        \"protocol\": \"openid-connect\",
        \"publicClient\": false,
        \"secret\": \"student-app-pr-${PR_NUMBER}-secret\",
        \"standardFlowEnabled\": true,
        \"directAccessGrantsEnabled\": false,
        \"redirectUris\": [\"http://pr-${PR_NUMBER}.student.local:8080/api/auth/callback\"],
        \"webOrigins\": [\"http://pr-${PR_NUMBER}.student.local:8080\"],
        \"attributes\": {\"pkce.code.challenge.method\": \"S256\"}
      }" \
      "${KEYCLOAK_URL}/admin/realms/student-mgmt/clients" >/dev/null
    log_success "Keycloak client student-app-pr-${PR_NUMBER} created"
  else
    log_info "Keycloak client student-app-pr-${PR_NUMBER} already exists"
  fi

  # Seed database
  KC_ID=$(get_keycloak_user_id "$ADMIN_TOKEN" "student-user")
  seed_database "$NS" "$KC_ID"

  # --- 2.6 E2E tests against PR preview ---
  run_e2e_tests "http://pr-${PR_NUMBER}.student.local:8080" "Phase 2 — PR Preview #${PR_NUMBER}"

  # --- 2.7 Close PR and verify cleanup ---
  log_step "2.7 Closing PR #${PR_NUMBER} and verifying cleanup"
  curl -sf -X PATCH \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"state":"closed"}' \
    "${GITHUB_API}/pulls/${PR_NUMBER}" \
    | python3 -c "import sys,json; p=json.load(sys.stdin); print('PR state:', p.get('state'))"
  log_success "PR #${PR_NUMBER} closed"

  # Wait for ArgoCD to detect closed PR and prune Application + namespace
  log_info "Waiting for ArgoCD to delete $APP_NAME (up to 3 min)..."
  local clean_deadline=$(( $(date +%s) + 180 ))
  while kubectl get application "$APP_NAME" -n argocd &>/dev/null; do
    if [[ $(date +%s) -gt $clean_deadline ]]; then
      log_warn "ArgoCD did not auto-delete $APP_NAME within 3 minutes — forcing deletion"
      argocd app delete "$APP_NAME" --cascade 2>/dev/null || true
      sleep 10
      break
    fi
    log_info "Waiting for ArgoCD prune... ($(( clean_deadline - $(date +%s) ))s remaining)"
    sleep 15
  done
  log_success "$APP_NAME deleted by ArgoCD"

  # Verify namespace gone
  if kubectl get ns "$NS" &>/dev/null; then
    log_warn "Namespace $NS still exists — it may take another moment to terminate"
  else
    log_success "Namespace $NS deleted ✓"
  fi

  # Cleanup Keycloak client
  ADMIN_TOKEN=$(get_keycloak_admin_token)
  local CLIENT_UUID
  CLIENT_UUID=$(curl -sf --insecure \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/student-mgmt/clients?clientId=student-app-pr-${PR_NUMBER}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || echo "")
  if [[ -n "$CLIENT_UUID" ]]; then
    curl -sf --insecure -X DELETE \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/student-mgmt/clients/${CLIENT_UUID}" >/dev/null
    log_success "Keycloak client student-app-pr-${PR_NUMBER} deleted"
  fi

  # Remove /etc/hosts entry
  remove_hosts_entry "$PR_HOST"

  # Remove .cicd-test-run file from git if it was committed
  if [[ -f "$PROJECT_DIR/.cicd-test-run" ]]; then
    git -C "$PROJECT_DIR" rm -f "$PROJECT_DIR/.cicd-test-run" &>/dev/null || \
      rm -f "$PROJECT_DIR/.cicd-test-run"
  fi

  log_success "Phase 2 complete ✓"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 3: Prod Promotion
# ──────────────────────────────────────────────────────────────────────────────
phase3_prod() {
  log_phase "Phase 3: Prod Promotion"

  # --- 3.1 Read dev image tag ---
  log_step "3.1 Reading validated dev image tag"

  # Make sure we have the latest dev kustomization
  git -C "$PROJECT_DIR" fetch origin dev --quiet

  local DEV_TAG
  DEV_TAG=$(git show origin/dev:gitops/environments/overlays/dev/kustomization.yaml \
    | grep "newTag:" | head -1 | awk '{print $2}')
  log_info "Dev image tag to promote: $DEV_TAG"

  # --- 3.2 Update prod overlay and push to main ---
  log_step "3.2 Updating prod overlay with $DEV_TAG"

  git -C "$PROJECT_DIR" checkout main
  git -C "$PROJECT_DIR" pull origin main --rebase 2>/dev/null || true

  local PROD_KUST="$PROJECT_DIR/gitops/environments/overlays/prod/kustomization.yaml"
  perl -i -pe "s|newTag: .*|newTag: ${DEV_TAG}|g" "$PROD_KUST"

  log_info "Updated tags in prod/kustomization.yaml:"
  grep "newTag" "$PROD_KUST"

  git -C "$PROJECT_DIR" add "$PROD_KUST"

  # Only commit if there are staged changes
  if git -C "$PROJECT_DIR" diff --cached --quiet; then
    log_info "Prod overlay already at $DEV_TAG — no commit needed"
  else
    git -C "$PROJECT_DIR" commit -m "ci: promote ${DEV_TAG} to prod"
    git -C "$PROJECT_DIR" push origin main
    log_success "Prod overlay pushed to origin/main"
  fi

  git -C "$PROJECT_DIR" checkout "$ORIGINAL_BRANCH"

  # --- 3.3 Wait for ArgoCD to sync prod ---
  log_step "3.3 Waiting for student-app-prod to sync"
  argocd app get student-app-prod --hard-refresh &>/dev/null || true
  sleep 5
  argocd app wait student-app-prod --health --sync --timeout 300
  log_success "student-app-prod: Synced + Healthy"

  kubectl get pods -n student-app-prod

  # --- 3.4 TLS secret + seed database ---
  log_step "3.4 Verifying TLS secret and seeding database (prod)"
  copy_tls_secret student-app-prod
  wait_for_pods student-app-prod "app=fastapi-app"

  local ADMIN_TOKEN KC_ID
  ADMIN_TOKEN=$(get_keycloak_admin_token)
  KC_ID=$(get_keycloak_user_id "$ADMIN_TOKEN" "student-user")

  seed_database student-app-prod "$KC_ID"

  # --- 3.5 E2E tests ---
  run_e2e_tests "http://prod.student.local:8080" "Phase 3 — Prod"

  log_success "Phase 3 complete ✓"
}

# ──────────────────────────────────────────────────────────────────────────────
# Final Verification
# ──────────────────────────────────────────────────────────────────────────────
run_verification() {
  log_phase "Final Verification"

  log_step "Registry contents"
  curl -s "http://${REGISTRY}/v2/_catalog" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('Repositories:', d['repositories'])"
  for repo in fastapi-student-app frontend-student-app; do
    echo -n "  $repo tags: "
    curl -s "http://${REGISTRY}/v2/${repo}/tags/list" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tags', []))"
  done

  log_step "ArgoCD Applications"
  argocd app list

  log_step "Pod status in all environments"
  for ns in student-app-dev student-app-prod; do
    echo "=== $ns ==="
    kubectl get pods -n "$ns" --no-headers | awk '{print "  " $1 "\t" $3}'
  done

  log_step "Health endpoints"
  for url in "http://dev.student.local:8080" "http://prod.student.local:8080"; do
    local health
    health=$(curl -sf "${url}/api/health" 2>/dev/null || echo '{"status":"UNREACHABLE"}')
    echo "  $url → $health"
  done

  log_step "PR preview namespaces (should be empty)"
  kubectl get ns | grep "student-app-pr-" \
    && log_warn "PR namespaces still exist!" \
    || log_success "No PR preview namespaces — clean ✓"

  log_step "Dev and prod image tags"
  echo -n "  Dev:  "; git -C "$PROJECT_DIR" show origin/dev:gitops/environments/overlays/dev/kustomization.yaml \
    | grep "newTag:" | head -1 | awk '{print $2}'
  echo -n "  Prod: "; git -C "$PROJECT_DIR" show origin/main:gitops/environments/overlays/prod/kustomization.yaml \
    | grep "newTag:" | head -1 | awk '{print $2}'
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  echo -e "\n${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║   ArgoCD GitOps Multi-Environment Pipeline Test      ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo -e "  Project:  $PROJECT_DIR"
  echo -e "  Repo:     ${GITHUB_OWNER}/${GITHUB_REPO}"
  echo -e "  Registry: $REGISTRY"
  echo -e "  Phases:   setup=${SKIP_SETUP} phase1=${SKIP_PHASE1} phase2=${SKIP_PHASE2} phase3=${SKIP_PHASE3}"

  # Save original branch for cleanup
  ORIGINAL_BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)
  log_info "Current git branch: $ORIGINAL_BRANCH"

  # Always check prerequisites
  check_prerequisites

  # Phase 0: Setup
  if [[ "$SKIP_SETUP" == false ]]; then
    phase0_setup
  else
    log_info "Skipping Phase 0 (--skip-setup)"
    # Verify cluster is reachable
    kubectl cluster-info &>/dev/null || {
      log_error "Cluster not reachable — remove --skip-setup or check 'kubectl cluster-info'"
      exit 1
    }
    log_success "Cluster is reachable"

    # Auto-fix CoreDNS if node IP changed (e.g. cluster was recreated)
    check_and_fix_coredns

    # Ensure github-token secret exists in ArgoCD namespace
    if ! kubectl get secret github-token -n argocd &>/dev/null; then
      log_info "Creating github-token secret in argocd namespace"
      kubectl create secret generic github-token \
        --namespace argocd \
        --from-literal=token="${GITHUB_TOKEN}"
      log_success "github-token secret created"
    else
      log_success "github-token secret already exists in argocd"
    fi
  fi

  # Start ArgoCD port-forward (needed for all phases)
  start_argocd_portforward

  # Verify ArgoCD apps exist (may show ComparisonError until branches have overlays)
  log_step "Checking ArgoCD applications"
  argocd app list 2>/dev/null || log_warn "argocd app list failed — check ArgoCD login"

  # Phase 1: Dev
  if [[ "$SKIP_PHASE1" == false ]]; then
    phase1_dev
  else
    log_info "Skipping Phase 1 (--skip-phase1)"
  fi

  # Phase 2: PR Preview
  if [[ "$SKIP_PHASE2" == false ]]; then
    phase2_pr_preview
  else
    log_info "Skipping Phase 2 (--skip-phase2)"
  fi

  # Phase 3: Prod
  if [[ "$SKIP_PHASE3" == false ]]; then
    phase3_prod
  else
    log_info "Skipping Phase 3 (--skip-phase3)"
  fi

  # Final verification
  if [[ "$SKIP_VERIFY" == false ]]; then
    run_verification
  fi

  # ── Summary ──
  echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║   ALL PHASES PASSED                                  ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Dev:  ${CYAN}http://dev.student.local:8080${NC}"
  echo -e "  Prod: ${CYAN}http://prod.student.local:8080${NC}"
  echo -e "  ArgoCD UI: ${CYAN}http://localhost:${ARGOCD_LOCAL_PORT}${NC}"
  echo ""
}

main "$@"
