# CI/CD Pipeline Test Instructions

Complete end-to-end guide for testing the ArgoCD GitOps multi-environment pipeline:
**PR Preview → Dev → Prod promotion** — both via the automated script **and** via Jenkins pipelines.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [One-Time Setup](#one-time-setup)
  - [Step 1: Start Registry and Cluster](#step-1-start-registry-and-cluster)
  - [Step 2: Setup Keycloak (base infrastructure)](#step-2-setup-keycloak-base-infrastructure)
  - [Step 3: Setup ArgoCD + Nginx Ingress + CoreDNS](#step-3-setup-argocd--nginx-ingress--coredns)
  - [Step 4: Setup Keycloak Clients for Dev and Prod](#step-4-setup-keycloak-clients-for-dev-and-prod)
  - [Step 5: /etc/hosts entries](#step-5-etchosts-entries)
  - [Step 6: GitHub Token for PR Generator](#step-6-github-token-for-pr-generator)
  - [Step 7: Create and push gitops branches](#step-7-create-and-push-gitops-branches)
  - [Step 8: Setup Jenkins](#step-8-setup-jenkins)
- [ArgoCD Credentials Reference](#argocd-credentials-reference)
- [Jenkins Credentials Reference](#jenkins-credentials-reference)
- [Jenkins Job Setup](#jenkins-job-setup)
  - [Dev Pipeline Job](#dev-pipeline-job)
  - [PR Preview Pipeline Job (Multibranch)](#pr-preview-pipeline-job-multibranch)
  - [Prod Pipeline Job](#prod-pipeline-job)
- [Phase 1: Dev Environment Pipeline](#phase-1-dev-environment-pipeline)
  - [1.1 Build and push dev images](#11-build-and-push-dev-images)
  - [1.2 Update dev overlay and push to git](#12-update-dev-overlay-and-push-to-git)
  - [1.3 Wait for ArgoCD sync](#13-wait-for-argocd-sync)
  - [1.4 Copy TLS secret and seed database](#14-copy-tls-secret-and-seed-database)
  - [1.5 Run E2E tests against dev](#15-run-e2e-tests-against-dev)
- [Phase 2: PR Preview Environment](#phase-2-pr-preview-environment)
  - [2.1 Create a PR](#21-create-a-pr)
  - [2.2 Build and push PR images](#22-build-and-push-pr-images)
  - [2.3 Label the PR to trigger ArgoCD](#23-label-the-pr-to-trigger-argocd)
  - [2.4 Wait for ArgoCD to create preview Application](#24-wait-for-argocd-to-create-preview-application)
  - [2.5 Setup preview environment](#25-setup-preview-environment)
  - [2.6 Run E2E tests against PR preview](#26-run-e2e-tests-against-pr-preview)
  - [2.7 Close PR and verify cleanup](#27-close-pr-and-verify-cleanup)
- [Phase 3: Prod Promotion](#phase-3-prod-promotion)
  - [3.1 Update prod overlay with dev image tag](#31-update-prod-overlay-with-dev-image-tag)
  - [3.2 Push to main to trigger ArgoCD sync](#32-push-to-main-to-trigger-argocd-sync)
  - [3.3 Wait for prod sync](#33-wait-for-argocd-to-sync-prod)
  - [3.4 Setup prod environment](#34-setup-prod-environment)
  - [3.5 Run E2E tests against prod](#35-run-e2e-tests-against-prod)
- [Automated Script](#automated-script)
- [Verification Checks](#verification-checks)
- [Troubleshooting](#troubleshooting)
- [Resuming from a Previous Session](#resuming-from-a-previous-session)
- [Service URLs](#service-urls)

---

## Prerequisites

Install the following tools before starting:

```bash
brew install kind kubectl argocd gh
brew install --cask docker  # Docker Desktop
```

Required for E2E tests:
```bash
cd frontend && npx playwright install chromium
```

**GitHub Personal Access Token** (PAT) with `repo` + `workflow` scopes — needed for ArgoCD PR generator and `gh` CLI.

---

## One-Time Setup

> Run these steps once per cluster lifecycle. If the cluster already exists and is healthy, skip to the relevant Phase.

### Step 1: Start Registry and Cluster

```bash
# Start the local Docker registry (port 5001)
bash scripts/setup-registry.sh

# Verify registry is running
curl http://localhost:5001/v2/_catalog
# Expected: {"repositories":[]}
```

Then run the base setup (certs, Kind cluster, Keycloak):
```bash
./setup.sh
```

This creates the cluster, Keycloak StatefulSet, realm, test users, Python venv, and npm packages.

> **Note:** `setup.sh` uses a fixed `cluster/kind-config.yaml` that:
> - Does NOT use `containerdConfigPatches` (causes kubelet crash on macOS + kindest/node:v1.35)
> - Uses Kind native `labels: {ingress-ready: "true"}` instead of `kubeadmConfigPatches`
> - Maps `containerPort: 80 → hostPort: 8080` for Nginx Ingress

### Step 2: Setup Keycloak (base infrastructure)

`setup.sh` handles this automatically. Verify:

```bash
# Keycloak should be healthy
curl -sk https://idp.keycloak.com:31111/realms/student-mgmt/.well-known/openid-configuration | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
# Expected: https://idp.keycloak.com:31111/realms/student-mgmt
```

### Step 3: Setup ArgoCD + Nginx Ingress + CoreDNS

```bash
bash scripts/setup-argocd.sh
```

This installs:
- **ArgoCD v3.0.5** (NodePort on 30080)
- **Nginx Ingress Controller** (listens on host port 8080)
- **CoreDNS override** — resolves `idp.keycloak.com` to the Kind node IP inside the cluster
- Both **ApplicationSets** (List Generator for dev/prod, PullRequest Generator for previews)
- Pre-copies `keycloak-tls` secret to `student-app-dev` and `student-app-prod` namespaces

Verify ArgoCD is ready:
```bash
# Port-forward (if NodePort 30080 is not mapped)
kubectl port-forward svc/argocd-server -n argocd 30080:80 &

# Login
argocd login localhost:30080 --insecure --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"

# List applications
argocd app list
# Expected: student-app-dev and student-app-prod (may show ComparisonError until branches exist)
```

### Step 4: Setup Keycloak Clients for Dev and Prod

```bash
bash scripts/setup-keycloak-envs.sh
```

This creates:
- `student-app-dev` client (secret: `student-app-dev-secret`, redirectUri: `http://dev.student.local:8080/...`)
- `student-app-prod` client (secret: `student-app-prod-secret`, redirectUri: `http://prod.student.local:8080/...`)

### Step 5: /etc/hosts entries

Add the following lines to `/etc/hosts` (requires `sudo`):

```
127.0.0.1  idp.keycloak.com
127.0.0.1  dev.student.local
127.0.0.1  prod.student.local
```

PR preview entries are added dynamically per PR (see Phase 2).

### Step 6: GitHub Token for PR Generator

```bash
# Replace YOUR_TOKEN with your GitHub PAT (needs: repo, workflow scopes)
kubectl create secret generic github-token \
  --namespace argocd \
  --from-literal=token=YOUR_TOKEN
```

Verify the token can access the repo:
```bash
GITHUB_TOKEN=YOUR_TOKEN
curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/a2z-ice/first-api-keycloak" | python3 -c "import sys,json; print(json.load(sys.stdin)['full_name'])"
# Expected: a2z-ice/first-api-keycloak
```

### Step 7: Create and push gitops branches

The ArgoCD List Generator watches the `dev` branch for dev and `main` branch for prod. Both need the `gitops/` overlay files.

```bash
# Create dev branch from cicd (which has all gitops files)
git checkout cicd
git push origin cicd:dev --force

# Merge cicd into main for prod support
git checkout main
git merge cicd --no-edit
git push origin main

# Return to cicd
git checkout cicd
```

### Step 8: Setup Jenkins

Jenkins runs as a Docker container with full access to Docker, kubectl, ArgoCD CLI, and the `gh` CLI. The custom image (`jenkins/Dockerfile`) pre-installs all required tools and plugins.

#### 8.1 Start Jenkins

```bash
bash scripts/setup-jenkins.sh
```

This script:
1. Generates `jenkins/kind-jenkins.config` — a kubeconfig using the Kind node's real internal IP (not `127.0.0.1`) so the Jenkins container can reach the Kubernetes API.
2. Starts Jenkins via `docker compose up -d` in the `jenkins/` directory.

Verify Jenkins is running:
```bash
docker ps | grep jenkins
# Expected: jenkins container, port 8090→8080
```

#### 8.2 Get initial admin password and unlock Jenkins

```bash
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Open **http://localhost:8090**, paste the password, then choose **Install suggested plugins**.

#### 8.3 Verify pre-installed tools in the Jenkins container

The `jenkins/Dockerfile` pre-installs all required tools. Confirm they are available:

```bash
docker exec jenkins bash -c "
  echo '--- Docker CLI ---' && docker version --format '{{.Client.Version}}'
  echo '--- kubectl ---' && kubectl version --client --short 2>/dev/null
  echo '--- argocd ---' && argocd version --client 2>/dev/null | head -1
  echo '--- node ---' && node --version
  echo '--- gh ---' && gh --version | head -1
"
```

Pre-installed Jenkins plugins (baked into the image):
- `git`, `github` — SCM integration
- `workflow-aggregator` — Pipeline DSL
- `credentials-binding` — `withCredentials` block support
- `blueocean` — modern pipeline UI
- `docker-workflow` — Docker build steps
- `kubernetes-cli` — kubectl in pipelines
- `ansicolor` — colored console output
- `pipeline-multibranch-defaults` — Multibranch Pipeline support

---

## ArgoCD Credentials Reference

| Credential | Value | How to retrieve |
|---|---|---|
| ArgoCD UI URL | http://localhost:30080 | NodePort — accessible from host |
| ArgoCD username | `admin` | Fixed |
| ArgoCD password | (auto-generated on install) | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |

Save the password — you will need it for the Jenkins `ARGOCD_PASSWORD` credential:
```bash
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
echo "ArgoCD password: $ARGOCD_PASSWORD"
```

Login via CLI:
```bash
argocd login localhost:30080 --insecure --username admin --password "$ARGOCD_PASSWORD"
```

> **Note:** The ArgoCD password changes every time the cluster is recreated. After a cluster reset, update the `ARGOCD_PASSWORD` credential in Jenkins.

---

## Jenkins Credentials Reference

Jenkins pipelines require two credentials configured in **Manage Jenkins → Credentials → System → Global credentials (unrestricted)**.

| Credential ID | Kind | Value | Used by |
|---|---|---|---|
| `GITHUB_TOKEN` | Secret text | GitHub PAT (`repo` + `workflow` scopes) | All three Jenkinsfiles — git push via HTTPS and `gh` CLI for PR create/merge/labels |
| `ARGOCD_PASSWORD` | Secret text | ArgoCD admin password (from above) | All three Jenkinsfiles — `argocd login` before `argocd app wait` |

> The pipelines push to git using HTTPS with token authentication:
> `git remote set-url origin https://x-access-token:${GITHUB_TOKEN}@github.com/a2z-ice/first-api-keycloak.git`
> No SSH key is needed.

### Adding credentials in Jenkins UI

1. Go to **http://localhost:8090** → **Manage Jenkins** → **Credentials**
2. Click **System** → **Global credentials (unrestricted)** → **+ Add Credentials**
3. Add `GITHUB_TOKEN`:
   - Kind: **Secret text**
   - Secret: paste your GitHub PAT
   - ID: `GITHUB_TOKEN`
   - Description: `GitHub Personal Access Token`
   - Click **Create**
4. Add `ARGOCD_PASSWORD`:
   - Kind: **Secret text**
   - Secret: paste the ArgoCD password (from `ARGOCD_PASSWORD` command above)
   - ID: `ARGOCD_PASSWORD`
   - Description: `ArgoCD Admin Password`
   - Click **Create**

### Adding credentials via REST API (alternative)

```bash
JENKINS_URL="http://localhost:8090"
JENKINS_PASS=$(docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword)
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

# Get CSRF crumb
CRUMB=$(curl -s -u "admin:${JENKINS_PASS}" \
  "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")

# Add GITHUB_TOKEN
curl -s -u "admin:${JENKINS_PASS}" -H "$CRUMB" \
  -X POST "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
  --data-urlencode 'json={
    "": "0",
    "credentials": {
      "scope": "GLOBAL",
      "id": "GITHUB_TOKEN",
      "description": "GitHub Personal Access Token",
      "secret": "'"${GITHUB_TOKEN}"'",
      "$class": "org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl"
    }
  }'

# Add ARGOCD_PASSWORD
curl -s -u "admin:${JENKINS_PASS}" -H "$CRUMB" \
  -X POST "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
  --data-urlencode 'json={
    "": "0",
    "credentials": {
      "scope": "GLOBAL",
      "id": "ARGOCD_PASSWORD",
      "description": "ArgoCD Admin Password",
      "secret": "'"${ARGOCD_PASS}"'",
      "$class": "org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl"
    }
  }'
```

---

## Jenkins Job Setup

Three pipeline jobs correspond to the three deployment phases. Each reads its `Jenkinsfile` from `jenkins/pipelines/`.

### Dev Pipeline Job

**Purpose:** Triggered by pushes to the `dev` branch. Builds images → pushes to registry → updates dev overlay → waits for ArgoCD sync → runs E2E tests → opens a promotion PR to `main`.

**Jenkinsfile:** `jenkins/pipelines/Jenkinsfile.dev`

**Create in Jenkins UI:**
1. **New Item** → name: `student-app-dev-pipeline` → type: **Pipeline** → OK
2. **General** → check **Do not allow concurrent builds**
3. Under **Pipeline**:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: `https://github.com/a2z-ice/first-api-keycloak.git`
   - Branch Specifier: `*/dev`
   - Script Path: `jenkins/pipelines/Jenkinsfile.dev`
4. **Build Triggers**: check **GitHub hook trigger for GITScm polling** (or **Poll SCM**: `H/5 * * * *`)
5. **Save**

**Credentials used:** `GITHUB_TOKEN`, `ARGOCD_PASSWORD`

**What it does on success:** Creates a promotion PR from `dev` → `main` via `gh pr create`. Merging that PR triggers the prod pipeline.

---

### PR Preview Pipeline Job (Multibranch)

**Purpose:** Automatically triggered for every PR opened against `dev`. Builds PR images tagged `pr-{N}-{8-char-sha}` → adds `preview` label to the PR (triggers ArgoCD PullRequest Generator) → copies TLS secret → waits for ArgoCD to create and sync the preview Application → registers Keycloak client → seeds database → runs E2E tests → merges the PR on success.

**Jenkinsfile:** `jenkins/pipelines/Jenkinsfile.pr-preview`

**Create in Jenkins UI:**
1. **New Item** → name: `student-app-pr-preview` → type: **Multibranch Pipeline** → OK
2. **Branch Sources** → **Add source** → **GitHub**
   - Credentials: add a GitHub credential (HTTPS with your PAT, or SSH key)
   - Repository: `a2z-ice/first-api-keycloak`
   - Behaviours: add **Filter by name (with wildcards)** if you only want PRs — leave default to scan all branches and PRs
3. **Build Configuration**:
   - Mode: **by Jenkinsfile**
   - Script Path: `jenkins/pipelines/Jenkinsfile.pr-preview`
4. **Scan Multibranch Pipeline Triggers**: check **Periodically if not otherwise run** (interval: 1 minute) or configure a GitHub webhook pointing to `http://localhost:8090/github-webhook/`
5. **Save**, then click **Scan Multibranch Pipeline Now**

**Credentials used:** `GITHUB_TOKEN`, `ARGOCD_PASSWORD`

**Key env vars injected automatically by GitHub Branch Source plugin:**
- `CHANGE_ID` — PR number (e.g., `5`)
- `GIT_COMMIT` — full SHA of the PR HEAD commit
- The pipeline derives `HEAD_SHORT_SHA = GIT_COMMIT.take(8)` — matches ArgoCD's `{{head_short_sha}}`

**Note:** The pipeline will error immediately if `CHANGE_ID` is not set (i.e., if triggered on a non-PR branch). This is by design.

---

### Prod Pipeline Job

**Purpose:** Triggered by pushes to `main`. Reads the validated dev image tag from the dev overlay → updates prod overlay → pushes to main → waits for ArgoCD sync → runs E2E tests against prod. No image rebuild — the same image validated in dev is reused.

**Jenkinsfile:** `jenkins/pipelines/Jenkinsfile.prod`

**Create in Jenkins UI:**
1. **New Item** → name: `student-app-prod-pipeline` → type: **Pipeline** → OK
2. **General** → check **Do not allow concurrent builds**
3. Under **Pipeline**:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: `https://github.com/a2z-ice/first-api-keycloak.git`
   - Branch Specifier: `*/main`
   - Script Path: `jenkins/pipelines/Jenkinsfile.prod`
4. **Build Triggers**: check **GitHub hook trigger for GITScm polling**
5. **Save**

**Credentials used:** `GITHUB_TOKEN`, `ARGOCD_PASSWORD`

---

## Phase 1: Dev Environment Pipeline

### 1.1 Build and push dev images

```bash
# Get current git SHA (7 chars)
GIT_SHA=$(git rev-parse --short HEAD)
IMAGE_TAG="dev-${GIT_SHA}"
echo "Building with tag: $IMAGE_TAG"

# Copy ca.crt into backend build context (required by Dockerfile)
mkdir -p backend/certs
cp certs/ca.crt backend/certs/ca.crt

# Build FastAPI image
docker build -t "localhost:5001/fastapi-student-app:${IMAGE_TAG}" ./backend
# Cleanup cert copy
rm -rf backend/certs

# Build frontend image
docker build -t "localhost:5001/frontend-student-app:${IMAGE_TAG}" ./frontend

# Push both images
docker push "localhost:5001/fastapi-student-app:${IMAGE_TAG}"
docker push "localhost:5001/frontend-student-app:${IMAGE_TAG}"

echo "Images pushed: $IMAGE_TAG"
```

### 1.2 Update dev overlay and push to git

```bash
git checkout dev

# Update image tags in kustomization.yaml
sed -i '' "s|newTag: .*|newTag: ${IMAGE_TAG}|g" \
  gitops/environments/overlays/dev/kustomization.yaml

# Verify the change
grep "newTag" gitops/environments/overlays/dev/kustomization.yaml

# Commit and push to dev branch
git add gitops/environments/overlays/dev/kustomization.yaml
git commit -m "ci: update dev image tags to ${IMAGE_TAG}"
git push origin dev
```

ArgoCD polls GitHub every 3 minutes (or use webhook). It will detect the commit and auto-sync `student-app-dev`.

### 1.3 Wait for ArgoCD sync

```bash
# Port-forward if needed
kubectl port-forward svc/argocd-server -n argocd 30080:80 &>/dev/null &
sleep 2

# Trigger immediate hard refresh (skip the 3-minute poll delay)
argocd app get student-app-dev --hard-refresh

argocd app wait student-app-dev --health --sync --timeout 300
```

Expected output: `student-app-dev` shows `Synced` and `Healthy`.

Check pod status:
```bash
kubectl get pods -n student-app-dev
# All pods should be Running/Ready
```

### 1.4 Copy TLS secret and seed database

> Skip TLS copy if `setup-argocd.sh` already did it (check: `kubectl get secret keycloak-tls -n student-app-dev`).

```bash
# Copy TLS secret if missing
kubectl get secret keycloak-tls -n student-app-dev 2>/dev/null || \
  kubectl get secret keycloak-tls -n keycloak -o yaml | \
    sed 's/namespace: keycloak/namespace: student-app-dev/' | \
    kubectl apply -f -

# Get student-user's Keycloak ID
KEYCLOAK_URL="https://idp.keycloak.com:31111"
ADMIN_TOKEN=$(curl -s -k -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

STUDENT_KC_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/student-mgmt/users?username=student-user&exact=true" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

# Seed the database
NS=student-app-dev
POD=$(kubectl get pod -n $NS -l app=fastapi-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $NS "$POD" -- python -c "
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
```

### 1.5 Run E2E tests against dev

```bash
# Verify health first
curl -s http://dev.student.local:8080/api/health
# Expected: {"status":"ok"}

# Run all 45 E2E tests
cd frontend
APP_URL=http://dev.student.local:8080 npx playwright test --reporter=line
```

Expected: **45 passed**

---

## Phase 2: PR Preview Environment

### 2.1 Create a PR

Create a feature branch with any change:

```bash
git checkout dev
git checkout -b feature/test-pr-preview

# Make a trivial change
echo "# PR Preview Test $(date)" >> /tmp/pr-note.txt
git add . || true
git commit --allow-empty -m "feat: test PR preview environment"
git push origin feature/test-pr-preview
```

Open a PR against `dev`:
```bash
GITHUB_TOKEN=YOUR_TOKEN
PR_NUMBER=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Test PR Preview Environment","head":"feature/test-pr-preview","base":"dev","body":"Testing ArgoCD PR preview pipeline"}' \
  "https://api.github.com/repos/a2z-ice/first-api-keycloak/pulls" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")

echo "Created PR #${PR_NUMBER}"
```

Or use the GitHub UI / `gh` CLI:
```bash
gh pr create --base dev --head feature/test-pr-preview \
  --title "Test PR Preview Environment" \
  --body "Testing ArgoCD PR preview pipeline"
```

### 2.2 Build and push PR images

> **Critical:** ArgoCD's `{{head_short_sha}}` template variable is **8 characters**. Build tags must match.

```bash
PR_NUMBER=1   # Replace with actual PR number
PR_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/a2z-ice/first-api-keycloak/pulls/${PR_NUMBER}" \
  | python3 -c "import sys,json; p=json.load(sys.stdin); print(p['head']['sha'][:8])")

echo "PR #${PR_NUMBER} SHA (8-char): $PR_SHA"
IMAGE_TAG="pr-${PR_NUMBER}-${PR_SHA}"
echo "Image tag: $IMAGE_TAG"

# Copy ca.crt
mkdir -p backend/certs && cp certs/ca.crt backend/certs/ca.crt

# Build and push
docker build -t "localhost:5001/fastapi-student-app:${IMAGE_TAG}" ./backend
rm -rf backend/certs
docker build -t "localhost:5001/frontend-student-app:${IMAGE_TAG}" ./frontend
docker push "localhost:5001/fastapi-student-app:${IMAGE_TAG}"
docker push "localhost:5001/frontend-student-app:${IMAGE_TAG}"

echo "PR images pushed: $IMAGE_TAG"
```

### 2.3 Label the PR to trigger ArgoCD

The ArgoCD PullRequest Generator watches for PRs with the `preview` label.

```bash
# Add 'preview' label via GitHub REST API (most reliable)
curl -s -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"labels":["preview"]}' \
  "https://api.github.com/repos/a2z-ice/first-api-keycloak/issues/${PR_NUMBER}/labels" \
  | python3 -c "import sys,json; [print(l['name']) for l in json.load(sys.stdin)]"
# Expected output: preview
```

### 2.4 Wait for ArgoCD to create preview Application

ArgoCD polls GitHub every 30 seconds. Within ~60s of the label being added:

```bash
echo "Waiting for ArgoCD to create student-app-pr-${PR_NUMBER}..."
for i in $(seq 1 8); do
  sleep 30
  echo "=== Check $i ($(date +%H:%M:%S)) ==="
  argocd app list 2>&1 | grep -E "NAME|pr-${PR_NUMBER}"
  kubectl get ns | grep "student-app-pr-${PR_NUMBER}" 2>/dev/null || echo "(namespace not yet created)"
done
```

Expected: `student-app-pr-{N}` appears in `argocd app list` as `Synced/Progressing`.

### 2.5 Setup preview environment

```bash
NS="student-app-pr-${PR_NUMBER}"

# Wait for pods to be scheduled
echo "Waiting for pods..."
until kubectl get pods -n $NS 2>/dev/null | grep -q "Running"; do
  sleep 5
done
kubectl get pods -n $NS

# Copy TLS secret
kubectl get secret keycloak-tls -n keycloak -o yaml | \
  sed "s/namespace: keycloak/namespace: ${NS}/" | kubectl apply -f -

# Create Keycloak client for this PR
KEYCLOAK_URL="https://idp.keycloak.com:31111"
ADMIN_TOKEN=$(curl -s -k -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -s -k -X POST "${KEYCLOAK_URL}/admin/realms/student-mgmt/clients" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"clientId\": \"student-app-pr-${PR_NUMBER}\",
    \"enabled\": true,
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"secret\": \"student-app-pr-${PR_NUMBER}-secret\",
    \"standardFlowEnabled\": true,
    \"redirectUris\": [\"http://pr-${PR_NUMBER}.student.local:8080/api/auth/callback\"],
    \"webOrigins\": [\"http://pr-${PR_NUMBER}.student.local:8080\"],
    \"attributes\": {\"pkce.code.challenge.method\": \"S256\"}
  }" | python3 -c "import sys; d=sys.stdin.read(); print('Client created' if not d else d[:100])"

# Add /etc/hosts entry (requires sudo)
grep -q "pr-${PR_NUMBER}.student.local" /etc/hosts || \
  echo "127.0.0.1 pr-${PR_NUMBER}.student.local" | sudo tee -a /etc/hosts

# Wait for ArgoCD sync and pods to be healthy
argocd app wait "student-app-pr-${PR_NUMBER}" --health --sync --timeout 180

# Seed database
STUDENT_KC_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/student-mgmt/users?username=student-user&exact=true" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

POD=$(kubectl get pod -n $NS -l app=fastapi-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $NS "$POD" -- python -c "
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
cs = db.query(Department).filter(Department.name == 'Computer Science').first()
kc_id = '${STUDENT_KC_ID}'
if not db.query(Student).filter(Student.keycloak_user_id == kc_id).first():
    db.add(Student(name='Student User', email='student-user@example.com', keycloak_user_id=kc_id, department_id=cs.id if cs else None))
    print('Created: Student User')
if not db.query(Student).filter(Student.email == 'other-student@example.com').first():
    db.add(Student(name='Other Student', email='other-student@example.com', department_id=cs.id if cs else None))
    print('Created: Other Student')
db.commit()
db.close()
"
```

### 2.6 Run E2E tests against PR preview

```bash
# Verify health
curl -s "http://pr-${PR_NUMBER}.student.local:8080/api/health"
# Expected: {"status":"ok"}

# Run E2E tests
cd frontend
APP_URL="http://pr-${PR_NUMBER}.student.local:8080" npx playwright test --reporter=line
```

Expected: **45 passed**

### 2.7 Close PR and verify cleanup

```bash
# Close the PR (without merging)
curl -s -X PATCH \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"state":"closed"}' \
  "https://api.github.com/repos/a2z-ice/first-api-keycloak/pulls/${PR_NUMBER}" \
  | python3 -c "import sys,json; p=json.load(sys.stdin); print('PR state:', p.get('state'))"

# Wait for ArgoCD to detect the closed PR and delete the Application (~30-60s)
echo "Waiting for ArgoCD to delete preview Application..."
for i in $(seq 1 4); do
  sleep 30
  echo "=== Check $i ==="
  argocd app list | grep "pr-${PR_NUMBER}" || echo "(Application deleted)"
  kubectl get ns | grep "student-app-pr-${PR_NUMBER}" || echo "(Namespace deleted)"
done
```

Expected: `student-app-pr-{N}` disappears from `argocd app list` and `kubectl get ns`.

Cleanup Keycloak client:
```bash
CLIENT_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/student-mgmt/clients?clientId=student-app-pr-${PR_NUMBER}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
[ -n "$CLIENT_ID" ] && curl -sk -X DELETE \
  "${KEYCLOAK_URL}/admin/realms/student-mgmt/clients/${CLIENT_ID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" && echo "Keycloak client deleted"
```

Remove /etc/hosts entry:
```bash
sudo sed -i '' "/pr-${PR_NUMBER}.student.local/d" /etc/hosts
```

---

## Phase 3: Prod Promotion

The prod overlay always uses the same image tag that was validated in dev. No rebuild needed.

### 3.1 Update prod overlay with dev image tag

```bash
git checkout main
git pull origin main

# Read the validated dev image tag
DEV_TAG=$(grep "newTag:" gitops/environments/overlays/dev/kustomization.yaml | head -1 | awk '{print $2}')
echo "Promoting to prod: $DEV_TAG"

# Update prod overlay
sed -i '' "s|newTag: .*|newTag: ${DEV_TAG}|g" \
  gitops/environments/overlays/prod/kustomization.yaml

# Verify
grep "newTag" gitops/environments/overlays/prod/kustomization.yaml
```

### 3.2 Push to main to trigger ArgoCD sync

```bash
git add gitops/environments/overlays/prod/kustomization.yaml
git commit -m "ci: promote ${DEV_TAG} to prod"
git push origin main
```

### 3.3 Wait for ArgoCD to sync prod

```bash
# Trigger immediate refresh
argocd app get student-app-prod --hard-refresh
sleep 5
argocd app wait student-app-prod --health --sync --timeout 300
kubectl get pods -n student-app-prod
```

### 3.4 Setup prod environment

```bash
# TLS secret (pre-copied by setup-argocd.sh, but verify)
kubectl get secret keycloak-tls -n student-app-prod 2>/dev/null || \
  kubectl get secret keycloak-tls -n keycloak -o yaml | \
    sed 's/namespace: keycloak/namespace: student-app-prod/' | kubectl apply -f -

# Seed database (same pattern as dev)
KEYCLOAK_URL="https://idp.keycloak.com:31111"
ADMIN_TOKEN=$(curl -s -k -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

STUDENT_KC_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/student-mgmt/users?username=student-user&exact=true" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

NS=student-app-prod
POD=$(kubectl get pod -n $NS -l app=fastapi-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $NS "$POD" -- python -c "
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
kc_id = '${STUDENT_KC_ID}'
if not db.query(Student).filter(Student.keycloak_user_id == kc_id).first():
    db.add(Student(name='Student User', email='student-user@example.com', keycloak_user_id=kc_id, department_id=cs.id if cs else None))
    print('Created: Student User')
else:
    print('Exists: Student User')
if not db.query(Student).filter(Student.email == 'other-student@example.com').first():
    db.add(Student(name='Other Student', email='other-student@example.com', department_id=cs.id if cs else None))
    print('Created: Other Student')
else:
    print('Exists: Other Student')
db.commit()
db.close()
"
```

### 3.5 Run E2E tests against prod

```bash
curl -s http://prod.student.local:8080/api/health
# Expected: {"status":"ok"}

cd frontend
APP_URL=http://prod.student.local:8080 npx playwright test --reporter=line
```

Expected: **45 passed**

---

## Automated Script

All three phases can be run automatically with the pipeline test script:

```bash
# Retrieve GITHUB_TOKEN from the k8s secret (if already stored there)
GITHUB_TOKEN=$(kubectl get secret github-token -n argocd -o jsonpath='{.data.token}' | base64 -d)

# Run all phases (infra already up — most common usage)
GITHUB_TOKEN=$GITHUB_TOKEN ./scripts/cicd-pipeline-test.sh --skip-setup

# Skip individual phases as needed
./scripts/cicd-pipeline-test.sh --skip-setup --skip-phase1          # Only PR Preview + Prod
./scripts/cicd-pipeline-test.sh --skip-setup --pr-number 5          # Reuse existing PR #5
./scripts/cicd-pipeline-test.sh --skip-setup --skip-phase2          # Only Dev + Prod
```

The script mirrors every manual step above, with added resilience:
- ArgoCD hard-refresh to skip the 3-minute poll delay
- Poll loops before `kubectl wait` to avoid "no matching resources" errors
- Restores `Student User` name if an edit test renamed it (idempotent seeding)
- No `sudo` usage — `/etc/hosts` entries are printed for manual addition

---

## Verification Checks

After completing all phases, run these to confirm everything is healthy:

```bash
# 1. Registry has all expected images
curl -s http://localhost:5001/v2/_catalog | python3 -c "import sys,json; print(json.load(sys.stdin))"

# 2. ArgoCD apps are all Synced/Healthy
argocd app list

# 3. All env namespaces have running pods
for ns in student-app-dev student-app-prod; do
  echo "=== $ns ==="
  kubectl get pods -n $ns --no-headers | awk '{print $3}' | sort | uniq -c
done

# 4. Health endpoints
for url in "http://dev.student.local:8080" "http://prod.student.local:8080"; do
  echo "$url: $(curl -s $url/api/health)"
done

# 5. No PR preview namespaces left
kubectl get ns | grep "student-app-pr" || echo "Clean: no preview namespaces"
```

---

## Troubleshooting

### ArgoCD shows ComparisonError for dev/prod

The `dev` or `main` branch doesn't have the gitops overlay files.
```bash
git checkout cicd && git push origin cicd:dev --force && git push origin cicd:main
```

### Pods stuck in ImagePullBackOff

Check the exact image tag ArgoCD is using:
```bash
kubectl describe pod -n student-app-dev -l app=fastapi-app | grep "Image:"
```
Compare against what's in the registry:
```bash
curl -s http://localhost:5001/v2/fastapi-student-app/tags/list
```
Retag and push if there's a mismatch.

### ArgoCD PR Generator generates 0 applications

1. Check github-token secret exists: `kubectl get secret github-token -n argocd`
2. Check controller logs: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=20 | grep -i "error\|pr"`
3. Verify PR has `preview` label via API:
   ```bash
   curl -s -H "Authorization: token $GITHUB_TOKEN" \
     "https://api.github.com/repos/a2z-ice/first-api-keycloak/pulls/1" \
     | python3 -c "import sys,json; p=json.load(sys.stdin); print('Labels:', [l['name'] for l in p['labels']])"
   ```
4. Re-add label via REST API (more reliable than `gh` CLI with limited token scopes):
   ```bash
   curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
     -d '{"labels":["preview"]}' \
     "https://api.github.com/repos/a2z-ice/first-api-keycloak/issues/1/labels"
   ```

### PR preview: image tag mismatch (7 vs 8 chars)

ArgoCD's `{{head_short_sha}}` is always **8 characters**. Always use:
```bash
PR_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/a2z-ice/first-api-keycloak/pulls/${PR_NUMBER}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['head']['sha'][:8])")
```

### OAuth login fails with `unauthorized_client`

The Keycloak client secret in the namespace doesn't match what Keycloak expects.
```bash
# Check what secret the pod has
kubectl get secret fastapi-app-secret -n student-app-dev \
  -o jsonpath='{.data.KEYCLOAK_CLIENT_SECRET}' | base64 -d
# Should be: student-app-dev-secret
```
If wrong, verify `gitops/environments/overlays/dev/patches/secret-patch.yaml` exists and is referenced in `kustomization.yaml`.

### Preview namespace not deleted after PR close

ArgoCD needs a successful GitHub API call to detect the closed PR. If network is flaky:
```bash
# Force-delete the ArgoCD Application manually
argocd app delete student-app-pr-1 --cascade
```

### `containerdConfigPatches` crashes kubelet on cluster create

Do NOT add `containerdConfigPatches` to `cluster/kind-config.yaml`. The registry mirror is configured post-creation by `setup-registry.sh` via `docker exec` writing to `/etc/containerd/certs.d/localhost:5001/hosts.toml` inside the Kind node.

### FastAPI pods get `httpx.ConnectError: All connection attempts failed` on `/api/auth/login`

This means the pods cannot reach Keycloak at `idp.keycloak.com:31111`. The CoreDNS hosts entry has a stale node IP (the IP changes when the cluster is recreated).

```bash
# Check current node IP
kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'

# Check what IP CoreDNS has
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' | grep idp

# Fix: patch CoreDNS with the correct node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
CURRENT=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')
NEW=$(echo "$CURRENT" | sed "s|[0-9.]\{7,15\} idp.keycloak.com|${NODE_IP} idp.keycloak.com|g")
kubectl patch configmap coredns -n kube-system --type=merge \
  -p "{\"data\":{\"Corefile\":$(echo "$NEW" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")}}"

# Restart CoreDNS and the FastAPI pods to flush DNS cache
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=60s
kubectl rollout restart deployment fastapi-app -n student-app-dev
kubectl rollout restart deployment fastapi-app -n student-app-prod
```

> **Prevention:** If you recreate the cluster, always re-run `bash scripts/setup-argocd.sh` rather than using `--skip-setup`.

### Jenkins cannot reach the Kubernetes API

The Jenkins container uses `jenkins/kind-jenkins.config`, which references the Kind node's real internal IP. If the cluster is recreated, regenerate the kubeconfig:
```bash
bash scripts/setup-jenkins.sh
```

### Jenkins ARGOCD_PASSWORD credential is wrong after cluster reset

The ArgoCD initial admin secret changes on every cluster creation. Update the credential:
```bash
NEW_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
echo "New ArgoCD password: $NEW_PASS"
# Update in Jenkins UI: Manage Jenkins → Credentials → ARGOCD_PASSWORD → Update
```

### Jenkins `gh pr edit --add-label` silently fails

`gh pr edit --add-label` requires `read:org` scope. If the PAT lacks that scope, use the GitHub REST API directly (what `cicd-pipeline-test.sh` does):
```bash
curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
  -d '{"labels":["preview"]}' \
  "https://api.github.com/repos/a2z-ice/first-api-keycloak/issues/${PR_NUMBER}/labels"
```

---

## Resuming from a Previous Session

If the cluster and infrastructure already exist, start here:

```bash
# 1. Verify cluster is running
kubectl cluster-info

# 2. Restore ArgoCD port-forward
kubectl port-forward svc/argocd-server -n argocd 30080:80 &>/dev/null &
sleep 2
argocd login localhost:30080 --insecure --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"

# 3. Check current state
argocd app list
kubectl get pods -n student-app-dev
kubectl get pods -n student-app-prod

# 4. Check registry
curl -s http://localhost:5001/v2/_catalog

# 5. Verify github-token secret in argocd namespace
kubectl get secret github-token -n argocd

# 6. Verify Jenkins is running
docker ps | grep jenkins

# 7. Continue from the phase you were on
```

**Key state to check when resuming:**
- Which git branches exist: `git branch -r`
- Current dev image tag: `grep newTag gitops/environments/overlays/dev/kustomization.yaml`
- Current prod image tag: `grep newTag gitops/environments/overlays/prod/kustomization.yaml`
- Open PRs: `curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/a2z-ice/first-api-keycloak/pulls | python3 -c "import sys,json; [print(f'PR #{p[\"number\"]}: {p[\"title\"]} | labels: {[l[\"name\"] for l in p[\"labels\"]]}') for p in json.load(sys.stdin)]"`

---

## Service URLs

| Service | URL | Notes |
|---------|-----|-------|
| Dev App | http://dev.student.local:8080 | ArgoCD syncs from `dev` branch |
| Prod App | http://prod.student.local:8080 | ArgoCD syncs from `main` branch |
| PR Preview | http://pr-{N}.student.local:8080 | Ephemeral; created when PR labeled `preview` |
| ArgoCD UI | http://localhost:30080 | admin / (see `argocd-initial-admin-secret`) |
| Jenkins UI | http://localhost:8090 | admin / (see `initialAdminPassword`) |
| Keycloak | https://idp.keycloak.com:31111 | admin / admin |
| Local Registry | http://localhost:5001/v2/_catalog | registry:2 container |

**Retrieve Jenkins admin password:**
```bash
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

**Retrieve ArgoCD admin password:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Test Users

| Username | Password | Role |
|----------|----------|------|
| `admin-user` | `admin123` | admin |
| `student-user` | `student123` | student |
| `staff-user` | `staff123` | staff |
