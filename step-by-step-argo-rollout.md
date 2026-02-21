# Step-by-Step: ArgoCD v3.3.1 + Argo Rollouts v1.8.4 Integration Test

> **Date:** 2026-02-20
> **Branch:** `argo-rollout` (pushed to `dev` and `main`)
> **Cluster:** Kind (keycloak-cluster), Node IP: 172.19.0.3
> **ArgoCD:** v3.3.1 — NodePort 30080/30081 (socat proxy), port-forward 18080 for CLI gRPC
> **Argo Rollouts:** v1.8.4 — namespace `argo-rollouts`

---

## Overview

This guide explains how to run the full canary deployment pipeline:

```
Phase 0  — Infrastructure readiness (cluster, ArgoCD, Argo Rollouts, registry)
Phase 1  — Dev deployment    → Canary Rollout → 45/45 E2E pass
Phase 2  — PR Preview        → Ephemeral canary env → E2E → auto-cleanup
Phase 3  — Prod promotion    → Same image, canary Rollout → 45/45 E2E pass
Phase 4  — Validation        → Rollout CRDs, history, ArgoCD health
```

The single-shot automation script is: `scripts/step-by-step-argo-rollout.sh`

---

## Test Results (2026-02-20)

### Infrastructure

| Check | Result |
|-------|--------|
| Kind cluster (keycloak-cluster) | ✅ Running, Node IP `172.19.0.3` |
| Keycloak v26.5.3 (3 replicas StatefulSet) | ✅ Healthy at `https://idp.keycloak.com:31111` |
| Local registry | ✅ `localhost:5001` |
| ArgoCD v3.3.1 | ✅ Synced + Healthy (both apps) |
| Argo Rollouts v1.8.4 controller | ✅ Running in `argo-rollouts` ns |
| Rollout CRDs registered | ✅ `rollouts.argoproj.io` + 4 others |

### Phase 1 — Dev (Canary Rollout)

| Item | Result |
|------|--------|
| ArgoCD app | ✅ `student-app-dev` Synced + Healthy |
| `fastapi-app` Rollout | ✅ DESIRED 2 / CURRENT 2 / AVAILABLE 2 |
| `frontend-app` Rollout | ✅ DESIRED 2 / CURRENT 2 / AVAILABLE 2 |
| Old Deployment resources | ✅ Pruned by ArgoCD |
| Canary strategy applied | ✅ setWeight 50% → pause 15s → 100% → pause 10s |
| E2E tests vs `http://dev.student.local:8080` | ✅ **45/45 passed** (18.2s) |

### Phase 3 — Prod (Canary Promotion)

| Item | Result |
|------|--------|
| ArgoCD app | ✅ `student-app-prod` Synced + Healthy |
| `fastapi-app` Rollout | ✅ DESIRED 2 / CURRENT 2 / AVAILABLE 2 |
| `frontend-app` Rollout | ✅ DESIRED 2 / CURRENT 2 / AVAILABLE 2 |
| Image tag promoted from dev | ✅ `dev-a5e4c43` (no rebuild) |
| E2E tests vs `http://prod.student.local:8080` | ✅ **45/45 passed** (15.9s) |

### E2E Test Breakdown

| Suite | Tests | Status |
|-------|-------|--------|
| Authentication | 7 | ✅ |
| Dark Mode | 3 | ✅ |
| Department Role-Based Access | 6 | ✅ |
| Department CRUD | 5 | ✅ |
| Error Handling | 3 | ✅ |
| Navigation | 4 | ✅ |
| Student Role-Based Access | 7 | ✅ |
| Student CRUD | 5 | ✅ |
| Form Validation | 5 | ✅ |
| **Total** | **45** | ✅ **All passed** |

### Issues Encountered & Resolved

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| ArgoCD CLI gRPC timeout via socat NodePort 30080 | socat TCP proxy doesn't forward HTTP/2 gRPC frames reliably | Used `kubectl port-forward svc/argocd-server 18080:80` for all CLI operations |
| E2E: 44/45 `#username` timeout (Keycloak login page unreachable) | CoreDNS stale IP (`172.19.0.2`) after cluster recreation — actual node IP is `172.19.0.3` | Patched CoreDNS Corefile + restarted coredns deployment + restarted fastapi Rollouts via `spec.restartAt` |
| Seed script: `ModuleNotFoundError: No module named 'app'` | Python cwd was `/` not `/app` | Added `sys.path.insert(0, '/app')` to inline seeder |

---

## Prerequisites

### One-Time Setup

```bash
# 1. /etc/hosts entries (required before any test)
sudo sh -c "echo '127.0.0.1 dev.student.local prod.student.local' >> /etc/hosts"

# 2. Per PR preview (look at script output for the PR number)
sudo sh -c "echo '127.0.0.1 pr-<N>.student.local' >> /etc/hosts"

# 3. GITHUB_TOKEN (only needed for PR preview phase)
#    Either export it or ensure the k8s secret exists:
kubectl get secret github-token -n argocd -o jsonpath='{.data.token}' | base64 -d
```

### Tools Required

| Tool | Why |
|------|-----|
| `kubectl` | Cluster management |
| `argocd` CLI v3.3.1 | App sync + wait |
| `docker` | Image builds + push |
| `git` | Overlay commits |
| `curl` | Keycloak Admin API |
| `python3` | DB seeding inline, JSON parsing |
| `npx` / Playwright | E2E test runner |
| `gh` CLI | PR management (Phase 2) |

---

## Phase 0 — Infrastructure Readiness

### Step 0.1 — Verify Cluster

```bash
kubectl cluster-info
kubectl get nodes
# Expected: keycloak-cluster-control-plane Ready
```

### Step 0.2 — Check ArgoCD Proxies

```bash
docker ps --filter name=argocd --format "table {{.Names}}\t{{.Status}}"
# Expected: argocd-http-proxy Up, argocd-https-proxy Up
```

If proxies are missing:
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
docker run -d --name argocd-http-proxy --network kind --restart unless-stopped \
  -p 30080:30080 alpine/socat TCP-LISTEN:30080,fork,reuseaddr TCP:${NODE_IP}:30080
docker run -d --name argocd-https-proxy --network kind --restart unless-stopped \
  -p 30081:30081 alpine/socat TCP-LISTEN:30081,fork,reuseaddr TCP:${NODE_IP}:30081
```

### Step 0.3 — Start ArgoCD Port-Forward (CLI gRPC)

> **Important:** The socat proxy handles HTTP but not gRPC (HTTP/2). The `argocd` CLI uses gRPC. Always use port-forward for ArgoCD CLI.

```bash
# Kill any existing port-forward on 18080
lsof -ti tcp:18080 | xargs kill -9 2>/dev/null || true

# Start port-forward in background
kubectl port-forward svc/argocd-server -n argocd 18080:80 &>/tmp/argocd-pf.log &
sleep 3

# Login
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:18080 --insecure --username admin --password "$ARGOCD_PASS"
# Expected: 'admin:login' logged in successfully
```

### Step 0.4 — Install Argo Rollouts (if not already installed)

```bash
kubectl get pods -n argo-rollouts 2>/dev/null | grep Running \
  && echo "already installed" || {
  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argo-rollouts \
    -f "https://github.com/argoproj/argo-rollouts/releases/download/v1.8.4/install.yaml"
  kubectl wait --namespace argo-rollouts \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=argo-rollouts \
    --timeout=120s
}

# Verify CRDs
kubectl get crd | grep rollouts.argoproj.io
# Expected: rollouts.argoproj.io   <timestamp>
```

### Step 0.5 — Check CoreDNS IP (Critical!)

CoreDNS has a `hosts` block mapping `idp.keycloak.com` to the Kind node IP. This IP changes when the cluster is recreated. **Always verify before running tests.**

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
COREFILE_IP=$(kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}' \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ idp\.keycloak' | awk '{print $1}')
echo "Node=$NODE_IP | CoreDNS=$COREFILE_IP"
```

If they differ, patch CoreDNS:
```bash
NEW_CF=$(kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}' \
  | sed "s|${COREFILE_IP} idp.keycloak.com|${NODE_IP} idp.keycloak.com|g")
kubectl patch configmap coredns -n kube-system --type=merge \
  -p "{\"data\":{\"Corefile\":$(echo "$NEW_CF" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")}}"
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=60s

# Restart fastapi Rollouts to pick up new DNS resolution
for NS in student-app-dev student-app-prod; do
  kubectl patch rollout fastapi-app -n "$NS" \
    -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" --type=merge \
    2>/dev/null && echo "Restarted fastapi-app in $NS" || true
done
```

### Step 0.6 — Remove Old Deployment Resources (Migration)

If the cluster previously had `apps/v1 Deployment` for fastapi-app/frontend-app, delete them before ArgoCD syncs Rollout resources (avoids label selector conflicts):

```bash
for NS in student-app-dev student-app-prod; do
  kubectl delete deployment fastapi-app frontend-app -n "$NS" 2>/dev/null || true
  kubectl delete replicasets -n "$NS" -l app=fastapi-app 2>/dev/null || true
  kubectl delete replicasets -n "$NS" -l app=frontend-app 2>/dev/null || true
done
echo "Cleanup done"
```

### Step 0.7 — Push Argo Rollout Branch to dev and main

```bash
# Ensure you are on the argo-rollout branch
git checkout argo-rollout

# Push to dev (ArgoCD watches dev branch for student-app-dev)
git push origin argo-rollout:dev --force

# Push to main (ArgoCD watches main branch for student-app-prod)
git push origin argo-rollout:main --force
```

### Step 0.8 — Verify ArgoCD Picks Up Rollout Manifests

```bash
# Force ArgoCD to refresh from git
argocd app get student-app-dev --server localhost:18080 --insecure --hard-refresh &>/dev/null
argocd app sync student-app-dev --server localhost:18080 --insecure --prune --force

# Wait for Healthy
argocd app wait student-app-dev --health --sync --timeout 300 \
  --server localhost:18080 --insecure

# Confirm Rollout resources
argocd app get student-app-dev --server localhost:18080 --insecure \
  | grep -E "Rollout|KIND"
# Expected:
# argoproj.io  Rollout  student-app-dev  fastapi-app   Synced  Healthy
# argoproj.io  Rollout  student-app-dev  frontend-app  Synced  Healthy
```

---

## Phase 1 — Dev Deployment with Canary Rollout

### Step 1.1 — Trigger Dev Sync (ArgoCD Auto or Manual)

ArgoCD polls git every 3 minutes automatically. To trigger immediately:

```bash
argocd app sync student-app-dev --server localhost:18080 --insecure --prune
argocd app wait student-app-dev --health --sync --timeout 300 \
  --server localhost:18080 --insecure
```

### Step 1.2 — Watch the Canary Roll Out

When a new image tag is deployed (or on first-time Rollout creation), watch the canary progression:

```bash
kubectl get rollout fastapi-app -n student-app-dev -w
```

Expected progression:
```
NAME          DESIRED   CURRENT   UP-TO-DATE   AVAILABLE
fastapi-app   2         3         1            2    ← canary pod created (50% weight)
fastapi-app   2         3         1            2    ← pausing 15s at setWeight 50
fastapi-app   2         3         2            2    ← setWeight 100, all pods updated
fastapi-app   2         2         2            2    ← pausing 10s, old pod removed
fastapi-app   2         2         2            2    ← Healthy ✓
```

Check the canary strategy configured:
```bash
kubectl describe rollout fastapi-app -n student-app-dev | grep -A 15 "Strategy:"
```

Expected output:
```
Strategy:
  Canary:
    Max Surge:        1
    Max Unavailable:  0
    Steps:
      Set Weight:  50
      Pause:
        Duration:  15s
      Set Weight:  100
      Pause:
        Duration:  10s
```

### Step 1.3 — Verify ArgoCD Tracks Rollout Health

```bash
argocd app get student-app-dev --server localhost:18080 --insecure
# Expected:
# Sync Status:   Synced
# Health Status: Healthy
# argoproj.io  Rollout  student-app-dev  fastapi-app   Synced  Healthy
# argoproj.io  Rollout  student-app-dev  frontend-app  Synced  Healthy
```

### Step 1.4 — Seed Database

```bash
TOKEN=$(curl -sf --insecure \
  -d 'client_id=admin-cli' -d 'username=admin' \
  -d 'password=admin' -d 'grant_type=password' \
  'https://idp.keycloak.com:31111/realms/master/protocol/openid-connect/token' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

KC_ID=$(curl -sf --insecure \
  -H "Authorization: Bearer $TOKEN" \
  'https://idp.keycloak.com:31111/admin/realms/student-mgmt/users?username=student-user&exact=true' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

DEV_POD=$(kubectl get pod -n student-app-dev -l app=fastapi-app \
  -o jsonpath='{.items[0].metadata.name}')

cat <<PYEOF | kubectl exec -n student-app-dev -i "$DEV_POD" -- python3 -
import sys; sys.path.insert(0, '/app')
from app.database import SessionLocal
from app.models import Student, Department
db = SessionLocal()
for name, desc in [('Computer Science','CS dept'),('Mathematics','Math dept'),('Physics','Physics dept')]:
    if not db.query(Department).filter(Department.name==name).first():
        db.add(Department(name=name, description=desc)); print('Created:', name)
db.commit()
cs = db.query(Department).filter(Department.name=='Computer Science').first()
kc_id = '${KC_ID}'
su = db.query(Student).filter(Student.keycloak_user_id==kc_id).first()
if not su:
    db.add(Student(name='Student User',email='student-user@example.com',keycloak_user_id=kc_id,department_id=cs.id if cs else None)); print('Created: Student User')
elif su.name != 'Student User':
    su.name='Student User'; su.email='student-user@example.com'; print('Restored: Student User')
else: print('Exists: Student User')
os_rec = db.query(Student).filter(Student.email=='other-student@example.com').first()
if not os_rec:
    db.add(Student(name='Other Student',email='other-student@example.com',department_id=cs.id if cs else None)); print('Created: Other Student')
elif os_rec.name != 'Other Student':
    os_rec.name='Other Student'; print('Restored: Other Student')
else: print('Exists: Other Student')
db.commit(); db.close(); print('Seed done.')
PYEOF
```

### Step 1.5 — Run E2E Tests Against Dev

```bash
cd frontend
APP_URL=http://dev.student.local:8080 npx playwright test --reporter=line
# Expected: 45 passed
```

---

## Phase 2 — PR Preview (Ephemeral Canary Environment)

> The PR preview environment is created by ArgoCD's PullRequest Generator when a PR with the `preview` label is opened against the repository. Each PR gets its own namespace (`student-app-pr-N`) with its own canary Rollout.

### Step 2.1 — Create a PR Preview Branch

```bash
PREVIEW_BRANCH="preview/argo-rollout-test-$(date +%s)"
git checkout -b "$PREVIEW_BRANCH"
git commit --allow-empty -m "test: trigger PR preview canary"
git push origin "$PREVIEW_BRANCH"
```

### Step 2.2 — Open PR and Label it `preview`

```bash
GH_TOKEN=$(kubectl get secret github-token -n argocd -o jsonpath='{.data.token}' | base64 -d)

PR_NUM=$(GH_TOKEN="$GH_TOKEN" gh pr create \
  --repo a2z-ice/first-api-keycloak \
  --title "test: Argo Rollouts PR preview" \
  --body "Automated ephemeral canary test." \
  --base main \
  --head "$PREVIEW_BRANCH" \
  | grep -oE '[0-9]+$')

# Label the PR to trigger ArgoCD PullRequest Generator
curl -sf -X POST \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"labels":["preview"]}' \
  "https://api.github.com/repos/a2z-ice/first-api-keycloak/issues/${PR_NUM}/labels"

echo "PR #$PR_NUM created and labeled"
```

### Step 2.3 — Add /etc/hosts Entry

```bash
# Add manually (script cannot sudo)
sudo sh -c "echo '127.0.0.1 pr-${PR_NUM}.student.local' >> /etc/hosts"
```

### Step 2.4 — Build + Push PR Images

```bash
SHORT_SHA=$(GH_TOKEN="$GH_TOKEN" gh pr view "$PR_NUM" \
  --repo a2z-ice/first-api-keycloak \
  --json headRefOid --jq '.headRefOid[:8]')

FASTAPI_IMAGE="localhost:5001/fastapi-student-app:pr-${PR_NUM}-${SHORT_SHA}"
FRONTEND_IMAGE="localhost:5001/frontend-student-app:pr-${PR_NUM}-${SHORT_SHA}"

docker build -t "$FASTAPI_IMAGE" ./backend && docker push "$FASTAPI_IMAGE"
docker build -t "$FRONTEND_IMAGE" ./frontend && docker push "$FRONTEND_IMAGE"
echo "Images pushed: pr-${PR_NUM}-${SHORT_SHA}"
```

### Step 2.5 — Register Keycloak Client for PR

```bash
KC_CLIENT_ID="student-app-pr-${PR_NUM}"
KC_CLIENT_SECRET="student-app-pr-${PR_NUM}-secret"
APP_URL="http://pr-${PR_NUM}.student.local:8080"

TOKEN=$(curl -sf --insecure \
  -d 'client_id=admin-cli' -d 'username=admin' -d 'password=admin' -d 'grant_type=password' \
  'https://idp.keycloak.com:31111/realms/master/protocol/openid-connect/token' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -sf --insecure -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"clientId\": \"${KC_CLIENT_ID}\", \"enabled\": true,
    \"protocol\": \"openid-connect\", \"publicClient\": false,
    \"secret\": \"${KC_CLIENT_SECRET}\",
    \"redirectUris\": [\"${APP_URL}/api/auth/callback\"],
    \"webOrigins\": [\"${APP_URL}\"],
    \"standardFlowEnabled\": true, \"directAccessGrantsEnabled\": false,
    \"attributes\": {\"pkce.code.challenge.method\": \"S256\"}
  }" \
  'https://idp.keycloak.com:31111/admin/realms/student-mgmt/clients' \
  && echo "Keycloak client created"
```

### Step 2.6 — Wait for ArgoCD to Create the Preview Namespace

ArgoCD's PullRequest Generator polls GitHub every ~30s. It creates namespace `student-app-pr-N` automatically.

```bash
PR_NS="student-app-pr-${PR_NUM}"
for i in $(seq 1 24); do
  kubectl get namespace "$PR_NS" &>/dev/null && echo "Namespace ready" && break
  echo "Waiting... (${i}/24)"
  sleep 5
done
```

### Step 2.7 — Copy TLS Secret to Preview Namespace

```bash
kubectl get secret keycloak-tls -n keycloak -o yaml \
  | sed "s/namespace: keycloak/namespace: ${PR_NS}/" \
  | kubectl apply -f -
```

### Step 2.8 — Wait for ArgoCD App to Go Healthy (Canary Completes)

```bash
ARGOCD_APP="student-app-pr-${PR_NUM}"
argocd app wait "$ARGOCD_APP" --health --sync --timeout 300 \
  --server localhost:18080 --insecure

# Confirm Rollouts in PR namespace
kubectl get rollouts -n "$PR_NS"
# Expected: fastapi-app and frontend-app both DESIRED 2 AVAILABLE 2
```

### Step 2.9 — Seed, E2E, Merge

```bash
# Seed (same pattern as Phase 1, using PR_NS)
# ... (see Phase 1 Step 1.4, substitute PR_NS)

# E2E
cd frontend
APP_URL="http://pr-${PR_NUM}.student.local:8080" npx playwright test --reporter=line

# Merge PR
GH_TOKEN="$GH_TOKEN" gh pr merge "$PR_NUM" \
  --repo a2z-ice/first-api-keycloak --merge --admin
```

### Step 2.10 — Auto-Cleanup Verification

After merge, ArgoCD's PullRequest Generator removes the `preview` label Application. ArgoCD prune-deletes all resources + namespace (~30s).

```bash
# Watch namespace disappear
kubectl get namespace "$PR_NS" --watch
# Should transition: Active → Terminating → (gone)

# Also remove /etc/hosts entry
sudo sed -i '' "/pr-${PR_NUM}.student.local/d" /etc/hosts
```

---

## Phase 3 — Prod Promotion (Canary)

No rebuild. The same image validated in dev is promoted to prod.

### Step 3.1 — Read Dev Image Tag

```bash
DEV_TAG=$(grep "newTag:" gitops/environments/overlays/dev/kustomization.yaml \
  | awk '{print $2}' | head -1)
echo "Promoting: $DEV_TAG"
```

### Step 3.2 — Update Prod Overlay

```bash
sed -i '' "s|newTag:.*|newTag: ${DEV_TAG}|g" \
  gitops/environments/overlays/prod/kustomization.yaml

git add gitops/environments/overlays/prod/kustomization.yaml
git commit -m "ci: promote ${DEV_TAG} to prod"
git push origin HEAD:main
```

### Step 3.3 — Wait for ArgoCD Sync + Canary Completion

```bash
argocd app wait student-app-prod --health --sync --timeout 300 \
  --server localhost:18080 --insecure

kubectl get rollouts -n student-app-prod
# Expected: fastapi-app and frontend-app DESIRED 2 AVAILABLE 2
```

### Step 3.4 — Seed and E2E

```bash
# Seed prod (same as Phase 1, with student-app-prod)

cd frontend
APP_URL=http://prod.student.local:8080 npx playwright test --reporter=line
# Expected: 45 passed
```

---

## Phase 4 — Validation & Canary Inspection

### Check All Rollout Status

```bash
# Dev
kubectl get rollouts -n student-app-dev

# Prod
kubectl get rollouts -n student-app-prod

# Expected output (both):
# NAME           DESIRED   CURRENT   UP-TO-DATE   AVAILABLE
# fastapi-app    2         2         2            2
# frontend-app   2         2         2            2
```

### Inspect Canary Strategy on a Rollout

```bash
kubectl describe rollout fastapi-app -n student-app-dev | grep -A 20 "Strategy:"
```

### View Rollout Events

```bash
kubectl describe rollout fastapi-app -n student-app-dev | awk '/Events:/,0'
# Expected events: RolloutUpdated, RolloutPaused, RolloutResumed, RolloutCompleted
```

### Rollout History

```bash
kubectl rollout history rollout/fastapi-app -n student-app-dev
# Expected: at least revision 1 with canary steps completed
```

### Trigger a Manual Canary (test restartAt)

```bash
kubectl patch rollout fastapi-app -n student-app-dev \
  -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" --type=merge

# Watch the canary steps
kubectl get rollout fastapi-app -n student-app-dev -w
```

### Confirm ArgoCD Version

```bash
argocd version --server localhost:18080 --insecure 2>&1 | head -2
# Expected: argocd: v3.3.1+...
```

### Confirm Rollout CRDs

```bash
kubectl get crd | grep argoproj.io
# Expected:
# analysisruns.argoproj.io
# analysistemplates.argoproj.io
# clusteranalysistemplates.argoproj.io
# experiments.argoproj.io
# rollouts.argoproj.io
```

---

## Single-Shot Automation

```bash
# Full run (all phases)
./scripts/step-by-step-argo-rollout.sh

# Skip infrastructure phase (cluster already running)
./scripts/step-by-step-argo-rollout.sh --skip-infra

# Skip build, use existing dev image tag
./scripts/step-by-step-argo-rollout.sh --skip-infra --dev-tag dev-a5e4c43

# Skip phases 1 and 2, only run prod
./scripts/step-by-step-argo-rollout.sh --skip-infra --skip-phase1 --skip-phase2

# Reuse existing open PR
./scripts/step-by-step-argo-rollout.sh --skip-infra --skip-phase1 --pr-number 7

# Dry run (print commands without executing)
./scripts/step-by-step-argo-rollout.sh --dry-run
```

Logs are saved to `test-results/argo-rollout-test-<timestamp>.log`.

---

## Troubleshooting

### ArgoCD CLI gRPC fails via port 30080

**Symptom:** `argocd login localhost:30080` → `gRPC connection not ready: context deadline exceeded`

**Cause:** socat TCP proxy does not handle HTTP/2 gRPC multiplexing reliably.

**Fix:** Always use port-forward for the argocd CLI:
```bash
kubectl port-forward svc/argocd-server -n argocd 18080:80 &
argocd login localhost:18080 --insecure --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"
```

> The HTTP UI (browser at `http://localhost:30080`) still works fine via socat.

### FastAPI → Keycloak `httpx.ConnectError`

**Symptom:** `/api/auth/login` returns 500. FastAPI logs show `httpx.ConnectError: All connection attempts failed`.

**Cause:** CoreDNS has stale node IP for `idp.keycloak.com`. Node IP changes on cluster recreation.

**Fix:** (see Phase 0 Step 0.5 above) Patch CoreDNS + restart coredns + restart fastapi Rollouts.

### `ModuleNotFoundError: No module named 'app'` in seed script

**Cause:** Python executes in `/` (root), not `/app`.

**Fix:** Always prepend `sys.path.insert(0, '/app')` before any `from app.xxx import ...`.

### `ErrImagePull` on PR preview pods

**Cause:** ArgoCD `{{head_short_sha}}` produces 8-char SHAs but image was tagged with 7-char SHA.

**Fix:** Always use `git rev-parse HEAD | cut -c1-8` (not `-c1-7`) when tagging PR images.

### Old `Deployment` coexists with new `Rollout` (selector conflict)

**Symptom:** ArgoCD sync fails, pods crash or don't start.

**Cause:** Both `apps/v1 Deployment` and `argoproj.io/v1alpha1 Rollout` share the same pod label selector. Their ReplicaSets fight.

**Fix:**
```bash
kubectl delete deployment fastapi-app frontend-app -n <NS> 2>/dev/null || true
kubectl delete replicasets -n <NS> -l app=fastapi-app 2>/dev/null || true
kubectl delete replicasets -n <NS> -l app=frontend-app 2>/dev/null || true
```

---

## Key Architecture Notes

### Canary Strategy — Replica-Based (No Service Mesh)

Argo Rollouts' canary with `maxSurge: 1` / `maxUnavailable: 0` on 2 replicas:

```
Normal state (2 pods):     [stable-0] [stable-1]
Canary start (setWeight 50%): [stable-0] [stable-1] [canary-0]  ← 3 pods
After pause 15s:           [stable-0] [canary-0]  [canary-1]   ← old pods removed
After setWeight 100%:      [canary-0] [canary-1]               ← complete
```

Traffic split is proportional to replica count (no ingress/Istio required).

### ArgoCD Health Checks for Rollouts

ArgoCD 3.x has built-in Lua health checks for Argo Rollouts resources. The `argocd app wait --health` command automatically waits for the Rollout to reach `Healthy` phase (after all canary steps complete). No manual polling needed.

### Restart Without Plugin

The `kubectl argo rollouts restart` command requires the kubectl plugin. The equivalent no-plugin command:
```bash
kubectl patch rollout <name> -n <ns> \
  -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" --type=merge
```
This sets `spec.restartAt` — the controller bumps the pod template annotation, triggering a new ReplicaSet and the full canary flow.

---

## File Reference

| File | Purpose |
|------|---------|
| `scripts/setup-argocd.sh` | Installs ArgoCD v3.3.1 + Argo Rollouts v1.8.4 (idempotent) |
| `scripts/step-by-step-argo-rollout.sh` | Single-shot full pipeline test |
| `gitops/environments/base/fastapi/deployment.yaml` | Rollout CRD (canary) for FastAPI |
| `gitops/environments/base/frontend/deployment.yaml` | Rollout CRD (canary) for Frontend |
| `gitops/environments/overlays/dev/kustomization.yaml` | Dev image tag (updated by CI) |
| `gitops/environments/overlays/prod/kustomization.yaml` | Prod image tag (promoted from dev) |
| `jenkins/pipelines/Jenkinsfile.pr-preview` | Jenkins PR preview pipeline (seed fixed) |
| `scripts/cicd-pipeline-test.sh` | Full automated pipeline test (3 phases) |
| `plans/6-argocd-v331-argo-rollouts.md` | Detailed implementation plan |
