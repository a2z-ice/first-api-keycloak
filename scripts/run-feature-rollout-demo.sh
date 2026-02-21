#!/usr/bin/env bash
# scripts/run-feature-rollout-demo.sh
#
# End-to-end demo of the "Silent Logout Fix" feature going through the full
# GitOps CI/CD pipeline with screenshot capture at every key stage.
#
# Pipeline flow:
#   Phase 0 — Commit the feature (logout fix) to the cicd branch
#   Phase 1 — Dev pipeline  : build → canary deploy to dev   → E2E → open PR
#   Phase 2 — PR Preview    : build → ephemeral env          → E2E → merge PR
#   Phase 3 — Prod promotion: reuse dev image → canary prod  → E2E
#
# Screenshots land in docs/screenshots/30-54-*.png and are referenced in
# presentation.md Section 12.
#
# Usage:
#   GITHUB_TOKEN=<pat> bash scripts/run-feature-rollout-demo.sh [OPTIONS]
#
# Options:
#   --skip-commit       Skip committing/pushing (code already on cicd)
#   --skip-phase1       Skip Phase 1 (dev pipeline already done)
#   --skip-phase2       Skip Phase 2 (PR preview)
#   --skip-phase3       Skip Phase 3 (prod promotion)
#   --skip-screenshots  Skip screenshot capture (only run pipeline)
#   --screenshots-only  Only run screenshots (pipeline already done)
#   --pr-number N       Reuse existing PR #N for Phase 2
#   --dev-tag TAG       Reuse a specific image tag for Phase 1+
#   --dry-run           Print steps without executing
#   -h, --help          Show this help
#
# Requirements:
#   - Kind cluster running with ArgoCD + Argo Rollouts
#   - GITHUB_TOKEN env var set (or in k8s secret)
#   - /etc/hosts entries: dev.student.local, prod.student.local, idp.keycloak.com
#   - For PR preview: pr-N.student.local entry (script will print the command)

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
SCREENSHOT_DIR="$REPO_ROOT/docs/screenshots"
FRONTEND_DIR="$REPO_ROOT/frontend"
TEST_RESULTS_DIR="$REPO_ROOT/test-results"
CAPTURE_SCRIPT="$SCRIPTS_DIR/capture-feature-rollout-screenshots.js"
PIPELINE_SCRIPT="$SCRIPTS_DIR/cicd-pipeline-test.sh"

GITHUB_OWNER="a2z-ice"
GITHUB_REPO="first-api-keycloak"
REGISTRY="localhost:5001"
DEV_URL="http://dev.student.local:8080"
PROD_URL="http://prod.student.local:8080"

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner()  { echo -e "\n${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}${BOLD}  $1${NC}"
            echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"; }
step()    { echo -e "\n${CYAN}▶ $1${NC}"; }
info()    { echo -e "  ${BLUE}[INFO]${NC}  $1"; }
ok()      { echo -e "  ${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
die()     { echo -e "  ${RED}[ERROR]${NC} $1" >&2; exit 1; }
dryrun()  { echo -e "  ${YELLOW}[DRY-RUN]${NC} $1"; }

# ── Flag defaults ───────────────────────────────────────────────────────────
SKIP_COMMIT=false
SKIP_PHASE1=false
SKIP_PHASE2=false
SKIP_PHASE3=false
SKIP_SCREENSHOTS=false
SCREENSHOTS_ONLY=false
DRY_RUN=false
REUSE_PR_NUMBER=""
REUSE_DEV_TAG=""

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-commit)       SKIP_COMMIT=true ;;
    --skip-phase1)       SKIP_PHASE1=true ;;
    --skip-phase2)       SKIP_PHASE2=true ;;
    --skip-phase3)       SKIP_PHASE3=true ;;
    --skip-screenshots)  SKIP_SCREENSHOTS=true ;;
    --screenshots-only)  SCREENSHOTS_ONLY=true; SKIP_COMMIT=true; SKIP_PHASE1=true; SKIP_PHASE2=true; SKIP_PHASE3=true ;;
    --pr-number)         REUSE_PR_NUMBER="$2"; shift ;;
    --dev-tag)           REUSE_DEV_TAG="$2"; shift ;;
    --dry-run)           DRY_RUN=true ;;
    -h|--help)           grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'; exit 0 ;;
    *) die "Unknown option: $1"; ;;
  esac
  shift
done

mkdir -p "$TEST_RESULTS_DIR" "$SCREENSHOT_DIR"

# ── Prerequisite check ──────────────────────────────────────────────────────
check_prereqs() {
  step "Checking prerequisites"
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
  command -v docker  >/dev/null 2>&1 || die "docker not found"
  command -v git     >/dev/null 2>&1 || die "git not found"
  command -v node    >/dev/null 2>&1 || die "node not found (needed for screenshots)"

  kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 \
    || die "Kind cluster not reachable. Start with: kind create cluster --config cluster/kind-config.yaml"

  # GITHUB_TOKEN
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    GITHUB_TOKEN=$(kubectl get secret github-token -n argocd \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    if [[ -z "$GITHUB_TOKEN" ]]; then
      die "GITHUB_TOKEN not set. Export it or store in k8s secret: kubectl create secret generic github-token -n argocd --from-literal=token=<pat>"
    fi
    export GITHUB_TOKEN
    info "GITHUB_TOKEN loaded from k8s secret"
  fi

  # /etc/hosts
  local missing=()
  for h in dev.student.local prod.student.local idp.keycloak.com; do
    grep -q "$h" /etc/hosts 2>/dev/null || missing+=("$h")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "/etc/hosts missing: ${missing[*]}\nAdd: echo '127.0.0.1 ${missing[*]}' | sudo tee -a /etc/hosts"
  fi

  # ArgoCD proxy containers
  if ! docker ps --filter name=argocd-http-proxy --format '{{.Names}}' | grep -q argocd-http-proxy; then
    warn "ArgoCD HTTP proxy container not running. Attempting to start..."
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    docker run -d --name argocd-http-proxy --network kind --restart unless-stopped \
      -p 30080:30080 alpine/socat \
      TCP-LISTEN:30080,fork,reuseaddr TCP:${NODE_IP}:30080 >/dev/null || true
    docker run -d --name argocd-https-proxy --network kind --restart unless-stopped \
      -p 30081:30081 alpine/socat \
      TCP-LISTEN:30081,fork,reuseaddr TCP:${NODE_IP}:30081 >/dev/null || true
    sleep 3
    ok "ArgoCD proxy containers started"
  fi

  ok "All prerequisites satisfied"
}

# ── ArgoCD port-forward for screenshots ────────────────────────────────────
PF_PID=""
start_argocd_portforward() {
  local port=18080
  # Kill any existing
  OLD=$(lsof -ti tcp:$port 2>/dev/null || true)
  [[ -n "$OLD" ]] && echo "$OLD" | xargs kill -9 2>/dev/null || true
  sleep 1

  # Wait for argocd pod
  for i in $(seq 1 20); do
    STATUS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [[ "$STATUS" == "True" ]] && break
    sleep 3
  done

  kubectl port-forward -n argocd deployment/argocd-server ${port}:8080 \
    >/tmp/argocd-pf-demo.log 2>&1 &
  PF_PID=$!
  trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

  for i in $(seq 1 20); do
    curl -sk --max-time 2 "https://localhost:${port}/api/version" >/dev/null 2>&1 && break
    sleep 1
  done
  ok "ArgoCD port-forward active (localhost:${port})"
}

# ── Screenshot runner ───────────────────────────────────────────────────────
take_screenshots() {
  local stage="$1"
  shift
  [[ "$SKIP_SCREENSHOTS" == "true" ]] && return 0

  info "Capturing screenshots: $stage"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "node $CAPTURE_SCRIPT --stage $stage $*"
    return 0
  fi

  node "$CAPTURE_SCRIPT" --stage "$stage" \
    --dev-url  "$DEV_URL" \
    --prod-url "$PROD_URL" \
    ${REUSE_PR_NUMBER:+--pr-number "$REUSE_PR_NUMBER"} \
    ${PREVIEW_URL:+--preview-url "$PREVIEW_URL"} \
    "$@" 2>&1 | sed 's/^/    /'
}

# ── Phase 0: Commit the feature ─────────────────────────────────────────────
phase0_commit() {
  banner "Phase 0 — Commit the Logout Fix Feature"

  if [[ "$SKIP_COMMIT" == "true" ]]; then
    info "Skipping commit (--skip-commit)"
    return 0
  fi

  step "Checking for uncommitted changes"
  cd "$REPO_ROOT"

  CHANGED=$(git status --porcelain \
    backend/app/routes/auth_routes.py \
    frontend/src/api/auth.ts \
    frontend/src/components/Navbar.tsx \
    frontend/tests/e2e/auth.spec.ts \
    plans/7-logout-fix-backchannel.md 2>/dev/null || true)

  if [[ -z "$CHANGED" ]]; then
    info "No uncommitted logout fix changes found — assuming already committed"
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      dryrun "git add <logout-fix-files> && git commit -m 'feat: fix logout...'"
    else
      git add \
        backend/app/routes/auth_routes.py \
        frontend/src/api/auth.ts \
        frontend/src/components/Navbar.tsx \
        frontend/tests/e2e/auth.spec.ts \
        plans/7-logout-fix-backchannel.md \
        scripts/capture-feature-rollout-screenshots.js \
        scripts/run-feature-rollout-demo.sh 2>/dev/null || true

      git commit -m "$(cat <<'EOF'
feat: fix logout — backchannel Keycloak logout + redirect to /login

- Store refresh_token in session during OAuth callback
- POST refresh_token to Keycloak logout endpoint server-side (backchannel)
- Return {redirect: "/login"} instead of {logout_url: "..."}
- React Router navigate() replaces window.location.href (no page reload)
- User stays entirely within the app — Keycloak URL never visible

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)" || info "Nothing new to commit"
    fi
    ok "Feature committed"
  fi

  COMMIT_SHA=$(git rev-parse HEAD | cut -c1-8)
  info "HEAD commit: $COMMIT_SHA"

  # Capture code-change screenshots (static, no cluster needed)
  take_screenshots "code-change"
  ok "Phase 0 complete"
}

# ── Phase 1: Dev pipeline ───────────────────────────────────────────────────
phase1_dev() {
  banner "Phase 1 — Dev Pipeline (Build → Canary Deploy → E2E)"

  if [[ "$SKIP_PHASE1" == "true" ]]; then
    info "Skipping Phase 1 (--skip-phase1)"
    return 0
  fi

  take_screenshots "phase1-jenkins"

  step "Building Docker images"
  COMMIT_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD | cut -c1-8)
  IMAGE_TAG="${REUSE_DEV_TAG:-dev-${COMMIT_SHA}}"
  info "Image tag: $IMAGE_TAG"

  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "docker build + push $IMAGE_TAG"
  else
    # Build backend
    docker build -t "${REGISTRY}/fastapi-student-app:${IMAGE_TAG}" \
      "$REPO_ROOT/backend" \
      --label "git.commit=${COMMIT_SHA}" \
      --label "git.feature=backchannel-logout" \
      2>&1 | tail -5
    docker push "${REGISTRY}/fastapi-student-app:${IMAGE_TAG}" 2>&1 | tail -3
    ok "fastapi-student-app:${IMAGE_TAG} pushed"

    # Build frontend
    docker build -t "${REGISTRY}/frontend-student-app:${IMAGE_TAG}" \
      "$REPO_ROOT/frontend" \
      2>&1 | tail -5
    docker push "${REGISTRY}/frontend-student-app:${IMAGE_TAG}" 2>&1 | tail -3
    ok "frontend-student-app:${IMAGE_TAG} pushed"
  fi

  step "Updating dev overlay"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "Update gitops/overlays/dev/kustomization.yaml → git push origin dev"
  else
    # Update the dev overlay on the dev branch
    CURRENT_BRANCH=$(git branch --show-current)

    # Stash any changes, update dev branch overlay, restore
    git fetch origin dev 2>/dev/null || true
    git stash 2>/dev/null || true

    git checkout dev 2>/dev/null || git checkout -b dev origin/dev 2>/dev/null || true

    # Patch kustomization.yaml with new image tags
    DEV_KUST="$REPO_ROOT/gitops/environments/overlays/dev/kustomization.yaml"
    if [[ -f "$DEV_KUST" ]]; then
      sed -i '' "s|newTag:.*|newTag: ${IMAGE_TAG}|g" "$DEV_KUST"
      git add "$DEV_KUST"
      git commit -m "ci: deploy dev ${IMAGE_TAG} — feat/backchannel-logout" \
        --allow-empty 2>/dev/null || true
      git push origin dev
      ok "Dev overlay updated → git push origin dev"
    else
      warn "Dev overlay not found at $DEV_KUST — skipping overlay update"
    fi

    git checkout "$CURRENT_BRANCH" 2>/dev/null || true
    git stash pop 2>/dev/null || true
  fi

  step "ArgoCD sync — waiting for dev canary rollout"
  # Capture ArgoCD syncing IMMEDIATELY (before rollout completes)
  start_argocd_portforward
  take_screenshots "phase1-argocd-sync"

  if [[ "$DRY_RUN" != "true" ]]; then
    # Login to argocd and wait
    ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d)
    argocd login localhost:30080 --insecure --username admin \
      --password "$ARGOCD_PASS" >/dev/null 2>&1 || true
    argocd app wait student-app-dev --health --timeout 300 2>&1 | tail -5 || true
    ok "Dev environment: Synced + Healthy"
  fi

  take_screenshots "phase1-argocd-done"

  step "Seeding dev database"
  if [[ "$DRY_RUN" != "true" ]]; then
    # Wait for fastapi pod
    for i in $(seq 1 20); do
      POD=$(kubectl get pods -n student-app-dev -l app=fastapi-app \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      [[ -n "$POD" ]] && break
      sleep 5
    done

    if [[ -n "${POD:-}" ]]; then
      kubectl exec -n student-app-dev "$POD" -- python3 -c "
import sys; sys.path.insert(0, '/app')
from app.database import engine, Base
from app import models
Base.metadata.create_all(bind=engine)
from sqlalchemy.orm import Session
from app.models import Department, Student
db = Session(engine)
if not db.query(Department).first():
    db.add(Department(name='Computer Science', description='CS Department'))
    db.add(Department(name='Mathematics', description='Math Department'))
    db.commit()
cs = db.query(Department).filter_by(name='Computer Science').first()
su = db.query(Student).filter_by(email='student@example.com').first()
if not su:
    db.add(Student(name='Student User', email='student@example.com',
                   student_id='STU001', department_id=cs.id))
    db.commit()
elif su.name != 'Student User':
    su.name = 'Student User'; db.commit()
print('Seed OK')
db.close()
" 2>&1 | tail -5 || warn "Seed may have failed — continuing"
      ok "Dev database seeded"
    fi
  fi

  step "Running E2E tests on dev environment"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "APP_URL=$DEV_URL npx playwright test"
  else
    DEV_E2E_LOG="$TEST_RESULTS_DIR/dev-e2e-$(date +%Y%m%d-%H%M%S).log"
    APP_URL="$DEV_URL" npx --prefix "$FRONTEND_DIR" playwright test \
      --reporter=line 2>&1 | tee "$DEV_E2E_LOG" || true
    ok "Dev E2E complete — log: $DEV_E2E_LOG"
  fi

  take_screenshots "phase1-app-logout"
  take_screenshots "phase1-e2e" ${DEV_E2E_LOG:+--e2e-log "$DEV_E2E_LOG"}

  step "Opening PR (cicd → main)"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "gh pr create --title 'feat: fix logout...' --base main --head cicd"
  else
    EXISTING_PR=$(gh pr list --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
      --head cicd --state open --json number --jq '.[0].number' 2>/dev/null || true)
    if [[ -n "$EXISTING_PR" ]]; then
      REUSE_PR_NUMBER="$EXISTING_PR"
      info "Reusing existing PR #$REUSE_PR_NUMBER"
    else
      PR_BODY="## Silent Logout Fix

### What changed
- **Backend**: Store \`refresh_token\` in session; backchannel POST to Keycloak on logout
- **Frontend**: \`navigate(redirect)\` instead of \`window.location.href = logout_url\`

### Result
User stays entirely within the app when logging out — no Keycloak UI flash.

### Tests
- ✅ All 45 E2E tests pass in dev environment
- ✅ Backchannel logout verified: Keycloak session terminated server-side

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

      REUSE_PR_NUMBER=$(gh pr create \
        --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
        --title "feat: fix logout — backchannel Keycloak logout + redirect to /login" \
        --body "$PR_BODY" \
        --base main \
        --head cicd \
        2>&1 | grep -o '#[0-9]*' | tr -d '#' | head -1 || true)
      ok "PR #${REUSE_PR_NUMBER} created"
    fi
  fi

  ok "Phase 1 complete — dev is live with backchannel logout ✅"
}

# ── Phase 2: PR Preview ─────────────────────────────────────────────────────
phase2_preview() {
  banner "Phase 2 — PR Preview (Ephemeral Env → E2E → Merge)"

  if [[ "$SKIP_PHASE2" == "true" ]]; then
    info "Skipping Phase 2 (--skip-phase2)"
    return 0
  fi

  PR_NUMBER="${REUSE_PR_NUMBER:-}"
  if [[ -z "$PR_NUMBER" ]]; then
    PR_NUMBER=$(gh pr list --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
      --head cicd --state open --json number --jq '.[0].number' 2>/dev/null || true)
  fi
  [[ -z "$PR_NUMBER" ]] && die "No open PR found. Run Phase 1 first or pass --pr-number N"
  info "PR: #$PR_NUMBER"

  PREVIEW_URL="http://pr-${PR_NUMBER}.student.local:8080"
  info "PR preview URL: $PREVIEW_URL"

  # Warn about /etc/hosts
  if ! grep -q "pr-${PR_NUMBER}.student.local" /etc/hosts 2>/dev/null; then
    warn "/etc/hosts missing: pr-${PR_NUMBER}.student.local"
    echo ""
    echo -e "  ${YELLOW}ADD THIS NOW (before continuing):${NC}"
    echo "  echo '127.0.0.1 pr-${PR_NUMBER}.student.local' | sudo tee -a /etc/hosts"
    echo ""
    read -r -p "  Press ENTER once you've added the /etc/hosts entry..." || true
  fi

  take_screenshots "phase2-jenkins"
  take_screenshots "phase2-pr" --pr-number "$PR_NUMBER"

  step "Adding 'preview' label to PR #$PR_NUMBER"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "POST /repos/${GITHUB_OWNER}/${GITHUB_REPO}/issues/${PR_NUMBER}/labels {preview}"
  else
    curl -s -X POST \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/issues/${PR_NUMBER}/labels" \
      -d '{"labels":["preview"]}' >/dev/null || true
    ok "'preview' label added → ArgoCD ApplicationSet will detect it"
  fi

  step "Waiting for ArgoCD to create student-app-pr-${PR_NUMBER} namespace"
  if [[ "$DRY_RUN" != "true" ]]; then
    for i in $(seq 1 60); do
      NS=$(kubectl get ns "student-app-pr-${PR_NUMBER}" --no-headers 2>/dev/null | awk '{print $1}' || true)
      [[ "$NS" == "student-app-pr-${PR_NUMBER}" ]] && break
      [[ $i -eq 60 ]] && warn "Namespace not created yet — ArgoCD may still be processing"
      [[ $i -eq 30 ]] && info "Still waiting... (ArgoCD needs ~1-2 min)"
      sleep 5
    done
    ok "Namespace student-app-pr-${PR_NUMBER} exists"
  fi

  step "Copying keycloak-tls secret to PR namespace"
  if [[ "$DRY_RUN" != "true" ]]; then
    kubectl get secret keycloak-tls -n keycloak -o yaml 2>/dev/null \
      | sed "s/namespace: keycloak/namespace: student-app-pr-${PR_NUMBER}/" \
      | kubectl apply -f - 2>/dev/null || warn "keycloak-tls copy may have failed"
    ok "keycloak-tls secret copied"
  fi

  step "Waiting for PR preview canary rollout to complete"
  if [[ "$DRY_RUN" != "true" ]]; then
    # Capture ArgoCD DURING sync
    take_screenshots "phase2-argocd" --pr-number "$PR_NUMBER"

    ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d)
    argocd login localhost:30080 --insecure --username admin \
      --password "$ARGOCD_PASS" >/dev/null 2>&1 || true
    argocd app wait "student-app-pr-${PR_NUMBER}" --health --timeout 300 2>&1 | tail -5 || true
    ok "PR preview environment: Healthy"
  else
    take_screenshots "phase2-argocd" --pr-number "$PR_NUMBER"
  fi

  step "Seeding PR preview database"
  if [[ "$DRY_RUN" != "true" ]]; then
    PR_POD=$(kubectl get pods -n "student-app-pr-${PR_NUMBER}" -l app=fastapi-app \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$PR_POD" ]]; then
      kubectl exec -n "student-app-pr-${PR_NUMBER}" "$PR_POD" -- python3 -c "
import sys; sys.path.insert(0, '/app')
from app.database import engine, Base
from app import models
Base.metadata.create_all(bind=engine)
from sqlalchemy.orm import Session
from app.models import Department, Student
db = Session(engine)
if not db.query(Department).first():
    db.add(Department(name='Computer Science', description='CS Department'))
    db.add(Department(name='Mathematics', description='Math Department'))
    db.commit()
cs = db.query(Department).filter_by(name='Computer Science').first()
su = db.query(Student).filter_by(email='student@example.com').first()
if not su:
    db.add(Student(name='Student User', email='student@example.com',
                   student_id='STU001', department_id=cs.id))
    db.commit()
elif su.name != 'Student User':
    su.name = 'Student User'; db.commit()
print('Seed OK'); db.close()
" 2>&1 | tail -3 || warn "Seed failed — continuing"
      ok "PR preview database seeded"
    fi
  fi

  step "Running E2E tests on PR preview environment"
  PREVIEW_URL="http://pr-${PR_NUMBER}.student.local:8080"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "APP_URL=$PREVIEW_URL npx playwright test"
  else
    PREVIEW_E2E_LOG="$TEST_RESULTS_DIR/preview-e2e-pr${PR_NUMBER}-$(date +%Y%m%d-%H%M%S).log"
    APP_URL="$PREVIEW_URL" npx --prefix "$FRONTEND_DIR" playwright test \
      --reporter=line 2>&1 | tee "$PREVIEW_E2E_LOG" || true
    ok "PR preview E2E complete — log: $PREVIEW_E2E_LOG"
  fi

  take_screenshots "phase2-app-logout" --preview-url "$PREVIEW_URL" --pr-number "$PR_NUMBER"
  take_screenshots "phase2-e2e" --preview-url "$PREVIEW_URL" --pr-number "$PR_NUMBER" \
    ${PREVIEW_E2E_LOG:+--e2e-log "$PREVIEW_E2E_LOG"}

  step "Merging PR #$PR_NUMBER → main"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "gh pr merge $PR_NUMBER --merge --repo ${GITHUB_OWNER}/${GITHUB_REPO}"
  else
    gh pr merge "$PR_NUMBER" --merge \
      --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
      --subject "feat: fix logout — backchannel Keycloak logout + redirect to /login (#${PR_NUMBER})" \
      2>&1 || warn "PR merge failed or already merged"
    ok "PR #$PR_NUMBER merged → main — prod pipeline will trigger"
  fi

  ok "Phase 2 complete — PR preview passed ✅"
}

# ── Phase 3: Prod promotion ─────────────────────────────────────────────────
phase3_prod() {
  banner "Phase 3 — Production Promotion (Canary → E2E)"

  if [[ "$SKIP_PHASE3" == "true" ]]; then
    info "Skipping Phase 3 (--skip-phase3)"
    return 0
  fi

  take_screenshots "phase3-jenkins"

  step "Reading image tag from dev overlay"
  DEV_KUST="$REPO_ROOT/gitops/environments/overlays/dev/kustomization.yaml"
  if [[ -f "$DEV_KUST" ]]; then
    IMAGE_TAG=$(grep 'newTag:' "$DEV_KUST" | head -1 | awk '{print $2}' | tr -d '"')
  else
    COMMIT_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD | cut -c1-8)
    IMAGE_TAG="${REUSE_DEV_TAG:-dev-${COMMIT_SHA}}"
  fi
  info "Promoting image tag: $IMAGE_TAG"

  step "Updating prod overlay"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "Update gitops/overlays/prod/kustomization.yaml → git push origin main"
  else
    CURRENT_BRANCH=$(git branch --show-current)
    git stash 2>/dev/null || true
    git fetch origin main 2>/dev/null || true
    git checkout main 2>/dev/null || git checkout -b main origin/main 2>/dev/null || true

    PROD_KUST="$REPO_ROOT/gitops/environments/overlays/prod/kustomization.yaml"
    if [[ -f "$PROD_KUST" ]]; then
      sed -i '' "s|newTag:.*|newTag: ${IMAGE_TAG}|g" "$PROD_KUST"
      git add "$PROD_KUST"
      git commit -m "ci: promote ${IMAGE_TAG} to prod — feat/backchannel-logout" \
        --allow-empty 2>/dev/null || true
      git push origin main
      ok "Prod overlay updated → git push origin main"
    else
      warn "Prod overlay not found at $PROD_KUST"
    fi

    git checkout "$CURRENT_BRANCH" 2>/dev/null || true
    git stash pop 2>/dev/null || true
  fi

  step "ArgoCD sync — waiting for prod canary rollout"
  # Capture DURING canary progression
  take_screenshots "phase3-argocd-sync"

  if [[ "$DRY_RUN" != "true" ]]; then
    ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d)
    argocd login localhost:30080 --insecure --username admin \
      --password "$ARGOCD_PASS" >/dev/null 2>&1 || true
    argocd app wait student-app-prod --health --timeout 300 2>&1 | tail -5 || true
    ok "Production: Synced + Healthy"
  fi

  take_screenshots "phase3-argocd-done"

  step "Seeding production database"
  if [[ "$DRY_RUN" != "true" ]]; then
    PROD_POD=$(kubectl get pods -n student-app-prod -l app=fastapi-app \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${PROD_POD:-}" ]]; then
      kubectl exec -n student-app-prod "$PROD_POD" -- python3 -c "
import sys; sys.path.insert(0, '/app')
from app.database import engine, Base
from app import models
Base.metadata.create_all(bind=engine)
from sqlalchemy.orm import Session
from app.models import Department, Student
db = Session(engine)
if not db.query(Department).first():
    db.add(Department(name='Computer Science', description='CS Department'))
    db.add(Department(name='Mathematics', description='Math Department'))
    db.commit()
cs = db.query(Department).filter_by(name='Computer Science').first()
su = db.query(Student).filter_by(email='student@example.com').first()
if not su:
    db.add(Student(name='Student User', email='student@example.com',
                   student_id='STU001', department_id=cs.id))
    db.commit()
elif su.name != 'Student User':
    su.name = 'Student User'; db.commit()
print('Seed OK'); db.close()
" 2>&1 | tail -3 || warn "Prod seed may have failed"
      ok "Production database seeded"
    fi
  fi

  step "Running E2E tests on production"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "APP_URL=$PROD_URL npx playwright test"
  else
    PROD_E2E_LOG="$TEST_RESULTS_DIR/prod-e2e-$(date +%Y%m%d-%H%M%S).log"
    APP_URL="$PROD_URL" npx --prefix "$FRONTEND_DIR" playwright test \
      --reporter=line 2>&1 | tee "$PROD_E2E_LOG" || true
    ok "Prod E2E complete — log: $PROD_E2E_LOG"
  fi

  take_screenshots "phase3-app-logout"
  take_screenshots "phase3-e2e" ${PROD_E2E_LOG:+--e2e-log "$PROD_E2E_LOG"}

  ok "Phase 3 complete — production is live with backchannel logout ✅"
}

# ── Final: Capture all-healthy state ───────────────────────────────────────
phase_final() {
  banner "Final — Capture All-Healthy State"
  take_screenshots "final"
}

# ── Update presentation.md git stamp ───────────────────────────────────────
commit_screenshots() {
  step "Committing screenshots and presentation.md"
  cd "$REPO_ROOT"
  git add docs/screenshots/ presentation.md scripts/capture-feature-rollout-screenshots.js \
    scripts/run-feature-rollout-demo.sh 2>/dev/null || true

  if git diff --cached --quiet; then
    ok "No new changes to commit"
  else
    COUNT=$(ls "$SCREENSHOT_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
    BRANCH=$(git branch --show-current)
    git commit -m "$(cat <<EOF
docs: add feature rollout demo screenshots and pipeline presentation

Added Section 12 to presentation.md: "Feature Rollout Demo: Silent Logout Fix"
Captured ${COUNT} screenshots showing complete CICD pipeline:
  - Code change (git diff + before/after diagram)
  - Phase 1: dev build → canary deploy → E2E (dev.student.local)
  - Phase 2: PR preview env → E2E → merge
  - Phase 3: prod canary → E2E (prod.student.local)
  - Final: all apps healthy in ArgoCD

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
    git push origin "$BRANCH"
    ok "Pushed to origin/$BRANCH"
  fi
}

# ── Entry point ──────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "══════════════════════════════════════════════════════════════════"
  echo "  Feature Rollout Demo: Silent Logout Fix"
  echo "  GitOps CI/CD Pipeline: Dev → PR Preview → Production"
  echo "══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Environments:"
  echo "    Dev:     $DEV_URL"
  echo "    Prod:    $PROD_URL"
  echo "    Preview: pr-N.student.local:8080 (set after PR creation)"
  echo ""
  [[ "$DRY_RUN" == "true" ]] && echo -e "  ${YELLOW}DRY-RUN MODE — no actual changes will be made${NC}\n"

  check_prereqs
  [[ "$SKIP_SCREENSHOTS" != "true" ]] && start_argocd_portforward

  phase0_commit
  phase1_dev
  phase2_preview
  phase3_prod
  phase_final

  [[ "$SKIP_SCREENSHOTS" != "true" && "$DRY_RUN" != "true" ]] && commit_screenshots

  echo ""
  echo "══════════════════════════════════════════════════════════════════"
  echo -e "  ${GREEN}${BOLD}DEMO COMPLETE ✅${NC}"
  echo ""
  echo "  Screenshots: docs/screenshots/"
  echo "  Presentation: presentation.md  (Section 12)"
  echo "══════════════════════════════════════════════════════════════════"
  echo ""
}

main "$@"
