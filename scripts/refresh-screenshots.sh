#!/usr/bin/env bash
# refresh-screenshots.sh — Capture all UI screenshots and push to Git
#
# What this script does:
#   1. Verifies prerequisites (node, kubectl, cluster, apps reachable)
#   2. Starts/restarts kubectl port-forward for ArgoCD (18080 → argocd-server:8080)
#   3. Installs Playwright Chromium browser if missing
#   4. Runs capture-screenshots.js (19 screenshots → docs/screenshots/)
#   5. Commits and pushes docs/screenshots/ + presentation.md to the current branch
#
# Usage:
#   bash scripts/refresh-screenshots.sh
#   bash scripts/refresh-screenshots.sh --no-push   # skip git commit/push
#   bash scripts/refresh-screenshots.sh --dry-run   # check prereqs only, skip capture

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/capture-screenshots.js"
SCREENSHOT_DIR="$REPO_ROOT/docs/screenshots"
FRONTEND_DIR="$REPO_ROOT/frontend"
PF_PORT=18080
PF_LOG="/tmp/argocd-pf-refresh.log"
NO_PUSH=false
DRY_RUN=false

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Parse flags ───────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --no-push)  NO_PUSH=true ;;
    --dry-run)  DRY_RUN=true ;;
    -h|--help)
      sed -n '/^#/p' "$0" | sed 's/^# \{0,1\}//' | head -16
      exit 0 ;;
    *) die "Unknown flag: $arg  (supported: --no-push, --dry-run)" ;;
  esac
done

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  refresh-screenshots.sh"
echo "══════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
info "Step 1 — Checking prerequisites"

command -v node    >/dev/null 2>&1 || die "node not found. Install Node.js."
command -v kubectl >/dev/null 2>&1 || die "kubectl not found."
command -v git     >/dev/null 2>&1 || die "git not found."
ok "node $(node --version), kubectl $(kubectl version --client -o json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo '?')"

# Cluster reachable?
kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 \
  || die "kubectl cannot reach the cluster. Is the Kind cluster running?"
ok "Kubernetes cluster reachable"

# /etc/hosts entries
HOSTS_MISSING=()
for h in dev.student.local prod.student.local idp.keycloak.com; do
  grep -q "$h" /etc/hosts 2>/dev/null || HOSTS_MISSING+=("$h")
done
if [[ ${#HOSTS_MISSING[@]} -gt 0 ]]; then
  warn "Missing /etc/hosts entries: ${HOSTS_MISSING[*]}"
  warn "Add them: echo '127.0.0.1 ${HOSTS_MISSING[*]}' | sudo tee -a /etc/hosts"
  die "Cannot take screenshots without /etc/hosts entries."
fi
ok "/etc/hosts entries present for dev.student.local, prod.student.local, idp.keycloak.com"

# Playwright install check (idempotent)
if [[ ! -d "$FRONTEND_DIR/node_modules/@playwright/test" ]]; then
  info "Installing frontend npm dependencies..."
  npm ci --prefix "$FRONTEND_DIR" --silent
fi

# Playwright Chromium browser (idempotent — skips download if already installed)
CHROMIUM_DIR=$(ls -d "$HOME/Library/Caches/ms-playwright/chromium-"* 2>/dev/null | head -1 || true)
if [[ -z "$CHROMIUM_DIR" ]]; then
  info "Installing Playwright Chromium browser (one-time, ~200 MB)..."
  npx --prefix "$FRONTEND_DIR" playwright install chromium
  ok "Chromium installed"
else
  ok "Playwright Chromium ready ($(basename "$CHROMIUM_DIR"))"
fi
echo ""

# ── Step 2: ArgoCD port-forward ───────────────────────────────────────────────
info "Step 2 — ArgoCD port-forward (localhost:$PF_PORT → argocd-server:8080)"

# Kill any existing process on PF_PORT
OLD_PIDS=$(lsof -ti tcp:$PF_PORT 2>/dev/null || true)
if [[ -n "$OLD_PIDS" ]]; then
  info "Killing existing process on port $PF_PORT (pid: $OLD_PIDS)"
  echo "$OLD_PIDS" | xargs kill -9 2>/dev/null || true
  sleep 1
fi

# Wait for argocd-server pod
info "Waiting for argocd-server pod to be Ready..."
for i in $(seq 1 20); do
  STATUS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$STATUS" == "True" ]] && break
  [[ $i -eq 20 ]] && die "argocd-server pod not ready. Check: kubectl get pods -n argocd"
  sleep 3
done
ok "argocd-server pod is Ready"

# Start port-forward in background
kubectl port-forward -n argocd deployment/argocd-server \
  ${PF_PORT}:8080 >"$PF_LOG" 2>&1 &
PF_PID=$!
# Ensure port-forward is killed when this script exits
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Wait for HTTPS to respond
info "Waiting for ArgoCD HTTPS on https://localhost:$PF_PORT..."
for i in $(seq 1 20); do
  if curl -sk --max-time 2 "https://localhost:$PF_PORT/api/version" >/dev/null 2>&1; then
    break
  fi
  [[ $i -eq 20 ]] && { warn "Port-forward log:"; cat "$PF_LOG"; die "ArgoCD not responding on https://localhost:$PF_PORT"; }
  sleep 1
done

ARGOCD_VER=$(curl -sk "https://localhost:$PF_PORT/api/version" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['Version'])" 2>/dev/null || echo "unknown")
ok "ArgoCD $ARGOCD_VER reachable at https://localhost:$PF_PORT"
echo ""

# ── Step 3: App URLs reachable ────────────────────────────────────────────────
info "Step 3 — Waiting for dev + prod app URLs"

wait_for_url() {
  local url="$1" label="$2"
  for i in $(seq 1 20); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || echo "000")
    if [[ "$CODE" =~ ^[23] ]]; then
      ok "$label → $url (HTTP $CODE)"
      return 0
    fi
    sleep 3
  done
  warn "$label not reachable at $url (last HTTP $CODE)"
  return 1
}

wait_for_url "http://dev.student.local:8080/"  "dev app " \
  || die "Dev app not reachable. Check: kubectl get pods -n student-app-dev"
wait_for_url "http://prod.student.local:8080/" "prod app" \
  || die "Prod app not reachable. Check: kubectl get pods -n student-app-prod"
echo ""

# ── Dry-run exit ──────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  ok "Dry-run complete — all prerequisites satisfied."
  ok "Run without --dry-run to capture screenshots."
  exit 0
fi

# ── Step 4: Capture screenshots ───────────────────────────────────────────────
info "Step 4 — Running capture-screenshots.js"
echo ""

mkdir -p "$SCREENSHOT_DIR"
node "$SCRIPT"

echo ""
COUNT=$(ls "$SCREENSHOT_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
ok "$COUNT screenshots saved to docs/screenshots/"
echo ""

# ── Step 5: Git commit + push ─────────────────────────────────────────────────
if [[ "$NO_PUSH" == "true" ]]; then
  info "Skipping git commit/push (--no-push flag set)"
else
  info "Step 5 — Committing and pushing to Git"
  cd "$REPO_ROOT"

  BRANCH=$(git branch --show-current)
  git add docs/screenshots/ scripts/capture-screenshots.js presentation.md 2>/dev/null || true

  if git diff --cached --quiet; then
    ok "No changes since last commit — nothing to push"
  else
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
    git commit -m "docs: refresh screenshots ($TIMESTAMP)

Recaptured $COUNT screenshots via scripts/refresh-screenshots.sh:
  - ArgoCD: app list, dev/prod detail, resource tree, rollout panel
  - Dev app: login, dashboard, students, departments, dark mode, student-role
  - Prod app: dashboard, students list
  - kubectl: rollouts, ArgoCD apps, controller, canary strategy, CRDs

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"

    git push origin "$BRANCH"
    ok "Pushed to origin/$BRANCH"
  fi
fi

echo ""
echo "══════════════════════════════════════════════════════════"
ok "Done! $COUNT screenshots captured."
echo ""
echo "  Screenshots:  docs/screenshots/"
echo "  Presentation: presentation.md"
[[ "$NO_PUSH" != "true" ]] && echo "  Branch:       $(git branch --show-current) (pushed)"
echo "══════════════════════════════════════════════════════════"
echo ""
