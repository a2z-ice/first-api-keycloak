# Plan 6: ArgoCD v3.3.1 Upgrade + Argo Rollouts Integration

> **Plan Name**: argocd-v331-argo-rollouts
> **Created**: 2026-02-20
> **Status**: Approved

---

## Overview

Upgrade ArgoCD from v3.0.5 to v3.3.1, install Argo Rollouts v1.8.4, convert the base `apps/v1 Deployment` resources for `fastapi-app` and `frontend-app` to `argoproj.io/v1alpha1 Rollout` CRDs with canary strategy, fix a seed-database bug in the PR preview Jenkinsfile, and run a full pipeline test to verify all three environments (dev, PR preview, prod).

---

## Context

- ArgoCD installed at v3.0.5 in `setup-argocd.sh`. Plans docs targeted v3.3.1.
- GitOps base at `gitops/environments/base/` uses standard Kubernetes `Deployment`. No Argo Rollouts resources exist yet.
- ArgoCD 3.3.x requires `--server-side --force-conflicts` on install (ApplicationSet CRD exceeds 256KB client-side apply annotation limit).
- `jenkins/pipelines/Jenkinsfile.pr-preview` has a broken seed stage: calls `kubectl exec ... -- python /app/scripts/create-test-data.py` which does not exist in the Docker image. Must use inline Python via `kubectl exec -i`.

---

## Files Changed

| File | Change |
|------|--------|
| `scripts/setup-argocd.sh` | v3.0.5→v3.3.1, server-side apply, add Rollouts v1.8.4 install block |
| `gitops/environments/base/fastapi/deployment.yaml` | Replace `apps/v1 Deployment` with `argoproj.io/v1alpha1 Rollout` + canary |
| `gitops/environments/base/frontend/deployment.yaml` | Replace `apps/v1 Deployment` with `argoproj.io/v1alpha1 Rollout` + canary |
| `scripts/cicd-pipeline-test.sh` | Fix `check_and_fix_coredns()` lines 362–368 for Rollouts; bump PR wait timeout line 730 |
| `jenkins/pipelines/Jenkinsfile.pr-preview` | Fix seed bug (inline Python), namespace wait 60s→120s, argocd timeout 180s→300s |
| `CLAUDE.md` | Update ArgoCD version, add Argo Rollouts section |
| `memory/MEMORY.md` | Update CI/CD state |

---

## Implementation Steps

### Step 1 — `scripts/setup-argocd.sh`

**a. Version variables and header (lines 2, 7)**
```bash
# Line 2: update comment
# setup-argocd.sh — Install/upgrade ArgoCD v3.3.1 + Argo Rollouts v1.8.4, ...

# Lines 7–8
ARGOCD_VERSION="v3.3.1"
ROLLOUTS_VERSION="v1.8.4"

# Line 11
echo "==> Setting up ArgoCD (${ARGOCD_VERSION}) + Argo Rollouts (${ROLLOUTS_VERSION})..."
```

**b. Server-side apply (lines 16–17)**

Replace:
```bash
kubectl apply -n "${ARGOCD_NAMESPACE}" -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
```
With:
```bash
kubectl apply -n "${ARGOCD_NAMESPACE}" \
    --server-side \
    --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
```

**c. Add Argo Rollouts install block after line 28 (after NodePort patch, before Nginx Ingress)**
```bash
# ---- Install Argo Rollouts ----
echo ""
echo "==> Installing Argo Rollouts (${ROLLOUTS_VERSION})..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts \
    -f "https://github.com/argoproj/argo-rollouts/releases/download/${ROLLOUTS_VERSION}/install.yaml"
echo "    Waiting for Argo Rollouts controller to be ready..."
kubectl wait --namespace argo-rollouts \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=argo-rollouts \
    --timeout=120s
echo "    Argo Rollouts ${ROLLOUTS_VERSION} installed."
```

---

### Step 2 — `gitops/environments/base/fastapi/deployment.yaml`

Full file replacement. Filename stays `deployment.yaml` (no kustomization.yaml change needed).

**Canary rationale:** `replicas: 2`, so setWeight 50% = 1 canary pod. `maxSurge: 1` allows a brief 3rd pod during promotion. Total extra time: 25s pauses + ~30s startup = ~55s. Well within 300s `argocd app wait` timeout.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: fastapi-app
  labels:
    app: fastapi-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: fastapi-app
  template:
    metadata:
      labels:
        app: fastapi-app
    spec:
      initContainers:
        - name: init-db
          image: fastapi-student-app
          imagePullPolicy: Always
          command: ["python", "-c", "from app.database import init_db; init_db()"]
          envFrom:
            - configMapRef:
                name: fastapi-app-config
            - secretRef:
                name: fastapi-app-secret
          volumeMounts:
            - name: keycloak-ca
              mountPath: /etc/ssl/keycloak
              readOnly: true
      containers:
        - name: fastapi-app
          image: fastapi-student-app
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
          envFrom:
            - configMapRef:
                name: fastapi-app-config
            - secretRef:
                name: fastapi-app-secret
          volumeMounts:
            - name: keycloak-ca
              mountPath: /etc/ssl/keycloak
              readOnly: true
          readinessProbe:
            httpGet:
              path: /api/health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /api/health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
      volumes:
        - name: keycloak-ca
          secret:
            secretName: keycloak-tls
            items:
              - key: ca.crt
                path: ca.crt
  strategy:
    canary:
      maxSurge: 1
      maxUnavailable: 0
      steps:
        - setWeight: 50
        - pause:
            duration: 15s
        - setWeight: 100
        - pause:
            duration: 10s
```

---

### Step 3 — `gitops/environments/base/frontend/deployment.yaml`

Same transformation, simpler canary (frontend is stateless Nginx).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: frontend-app
  labels:
    app: frontend-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend-app
  template:
    metadata:
      labels:
        app: frontend-app
    spec:
      containers:
        - name: frontend-app
          image: frontend-student-app
          imagePullPolicy: Always
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
  strategy:
    canary:
      maxSurge: 1
      maxUnavailable: 0
      steps:
        - setWeight: 50
        - pause:
            duration: 10s
```

---

### Step 4 — `scripts/cicd-pipeline-test.sh`

**a. Fix `check_and_fix_coredns()` lines 361–369**

Uses existing `wait_for_pods` helper (`wait_for_pods NS LABEL TIMEOUT` at line 386). No new dependencies; no `kubectl argo rollouts` plugin required. The `spec.restartAt` patch is the Argo Rollouts native no-plugin restart mechanism.

Replace:
```bash
  for ns in student-app-dev student-app-prod; do
    if kubectl get deployment fastapi-app -n "$ns" &>/dev/null; then
      log_info "Restarting fastapi-app in $ns"
      kubectl rollout restart deployment fastapi-app -n "$ns"
    fi
  done
  if kubectl get deployment fastapi-app -n student-app-dev &>/dev/null; then
    kubectl rollout status deployment fastapi-app -n student-app-dev --timeout=120s 2>/dev/null || true
  fi
```
With:
```bash
  for ns in student-app-dev student-app-prod; do
    if kubectl get rollout fastapi-app -n "$ns" &>/dev/null; then
      log_info "Restarting fastapi-app Rollout in $ns"
      kubectl patch rollout fastapi-app -n "$ns" \
        -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" \
        --type=merge
    elif kubectl get deployment fastapi-app -n "$ns" &>/dev/null; then
      log_info "Restarting fastapi-app Deployment in $ns"
      kubectl rollout restart deployment fastapi-app -n "$ns"
    fi
  done
  # Wait for pods Running (works for both Rollout and Deployment)
  if kubectl get pods -n student-app-dev -l app=fastapi-app &>/dev/null; then
    wait_for_pods "student-app-dev" "app=fastapi-app" 120
  fi
```

**b. Bump PR preview `argocd app wait` timeout (line 730): 180 → 300**
```bash
  argocd app wait "$APP_NAME" --health --sync --timeout 300
```

---

### Step 5 — `jenkins/pipelines/Jenkinsfile.pr-preview`

**a. Namespace wait iterations (line 93): `seq 1 12` → `seq 1 24`; update log message (line 98) `/12` → `/24`**

**b. ArgoCD wait timeout (line 116): `180` → `300`**

**c. Replace Seed Database stage (lines 164–171)**

Groovy triple-double-quote `"""..."""` block: Groovy variables expand (`${PR_NS}`, `${KEYCLOAK_URL}`, `${KEYCLOAK_REALM}`); shell variables escaped with backslash (`\${TOKEN}`, `\${KC_ID}`, `\${POD}`). Shell `\${KC_ID}` expands at runtime and is injected into Python string (same technique as `cicd-pipeline-test.sh` unquoted `<<PYEOF` heredoc).

```groovy
stage('Seed Database') {
    steps {
        sh """
            TOKEN=\$(curl -sf --insecure \\
                -d 'client_id=admin-cli' -d 'username=admin' \\
                -d 'password=admin' -d 'grant_type=password' \\
                '${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token' \\
                | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

            KC_ID=\$(curl -sf --insecure \\
                -H "Authorization: Bearer \${TOKEN}" \\
                '${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?username=student-user&exact=true' \\
                | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

            POD=\$(kubectl get pod -n ${PR_NS} -l app=fastapi-app \\
                -o jsonpath='{.items[0].metadata.name}')

            SEED_PY=\$(cat <<PYEOF
from app.database import SessionLocal
from app.models import Student, Department
db = SessionLocal()
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
kc_id = '\${KC_ID}'
su = db.query(Student).filter(Student.keycloak_user_id == kc_id).first()
if not su:
    db.add(Student(name='Student User', email='student-user@example.com',
                   keycloak_user_id=kc_id, department_id=cs.id if cs else None))
    print('Created: Student User')
elif su.name != 'Student User':
    su.name = 'Student User'
    su.email = 'student-user@example.com'
    print('Restored name: Student User')
else:
    print('Exists: Student User')
os_rec = db.query(Student).filter(Student.email == 'other-student@example.com').first()
if not os_rec:
    db.add(Student(name='Other Student', email='other-student@example.com',
                   department_id=cs.id if cs else None))
    print('Created: Other Student')
elif os_rec.name != 'Other Student':
    os_rec.name = 'Other Student'
    print('Restored name: Other Student')
else:
    print('Exists: Other Student')
db.commit()
db.close()
PYEOF
)
            echo "\${SEED_PY}" | kubectl exec -n ${PR_NS} -i "\${POD}" -- python
        """
    }
}
```

---

### Step 6 — Documentation

**`CLAUDE.md`:**
- Update `ArgoCD: v3.0.5` → `v3.3.1` in the CI/CD state section
- Add to Patterns & Gotchas:
  ```
  - **Argo Rollouts canary**: fastapi-app and frontend-app use Rollout CRDs (not Deployment).
    ArgoCD 3.x tracks Rollout health natively — argocd app wait --health waits for canary
    completion. To watch: kubectl get rollout fastapi-app -n student-app-dev -w.
    No kubectl-argo-rollouts plugin required for the pipeline.
  - **Rollout restart in check_and_fix_coredns**: uses kubectl patch rollout ... restartAt
    (not kubectl rollout restart deployment). The elif branch handles pre-Rollout clusters.
  ```

**`memory/MEMORY.md`:**
- CI/CD State: ArgoCD v3.3.1, Argo Rollouts v1.8.4
- Add Rollouts restart pattern to Patterns & Gotchas

---

### Step 7 — Pre-test Cluster Cleanup

Run BEFORE pushing Rollout YAML to git branches. Prevents ReplicaSet selector conflicts when ArgoCD creates Rollout resources alongside existing Deployment ReplicaSets.

```bash
kubectl delete deployment fastapi-app frontend-app -n student-app-dev 2>/dev/null || true
kubectl delete deployment fastapi-app frontend-app -n student-app-prod 2>/dev/null || true
kubectl delete replicasets -n student-app-dev -l app=fastapi-app 2>/dev/null || true
kubectl delete replicasets -n student-app-dev -l app=frontend-app 2>/dev/null || true
kubectl delete replicasets -n student-app-prod -l app=fastapi-app 2>/dev/null || true
kubectl delete replicasets -n student-app-prod -l app=frontend-app 2>/dev/null || true
```

---

### Step 8 — Upgrade and Full Pipeline Test

```bash
# 1. Upgrade ArgoCD in-place + install Rollouts (idempotent)
bash scripts/setup-argocd.sh

# 2. Commit all changes on cicd branch, then push to dev and main
git push origin cicd:dev --force
git checkout main && git merge cicd && git push origin main && git checkout cicd

# 3. Run full pipeline test (dev → PR preview → prod)
GITHUB_TOKEN=$(kubectl get secret github-token -n argocd \
  -o jsonpath='{.data.token}' | base64 -d)
GITHUB_TOKEN=$GITHUB_TOKEN ./scripts/cicd-pipeline-test.sh --skip-setup
```

---

## Argo Rollouts Test Plan

### T1 — Controller Health

```bash
kubectl get pods -n argo-rollouts
# Expected: 1 pod Running (argo-rollouts-<hash>)

kubectl get crd | grep argoproj
# Expected: rollouts.argoproj.io, analysisruns.argoproj.io,
#           analysistemplates.argoproj.io, clusteranalysistemplates.argoproj.io,
#           experiments.argoproj.io
```

### T2 — ArgoCD Version Confirmed

```bash
argocd version --server localhost:30080 --insecure --client
# Expected: argocd: v3.3.1+...
```

### T3 — Rollout Resources Created

After Phase 1 (dev) syncs:
```bash
kubectl get rollouts -n student-app-dev
# NAME           DESIRED   CURRENT   UP-TO-DATE   AVAILABLE
# fastapi-app    2         2         2            2
# frontend-app   2         2         2            2

kubectl get rollouts -n student-app-prod
# Same expected output after Phase 3
```

### T4 — Canary Steps Observed During Deployment

When a new image tag is pushed to dev overlay (Phase 1 or subsequent deploys), watch the progression:

```bash
kubectl get rollout fastapi-app -n student-app-dev -w
# Expected sequence:
#   Phase: Progressing  Weight: 0    ← initial
#   Phase: Progressing  Weight: 50   ← after setWeight: 50 (1 canary pod)
#   Phase: Progressing  Weight: 50   ← during 15s pause
#   Phase: Progressing  Weight: 100  ← after setWeight: 100
#   Phase: Progressing  Weight: 100  ← during 10s pause
#   Phase: Healthy      Weight: 100  ← promotion complete
```

Confirm events:
```bash
kubectl describe rollout fastapi-app -n student-app-dev | grep -A30 "Events:"
# Expected events: RolloutUpdated, ScaleDownOldRS, RolloutPaused, RolloutResumed, RolloutCompleted
```

### T5 — ArgoCD Tracks Rollout Health

```bash
argocd app get student-app-dev
# Expected:
#   Sync Status:   Synced
#   Health Status: Healthy
#   ...
#   Rollout/fastapi-app    Synced  Healthy
#   Rollout/frontend-app   Synced  Healthy
```

### T6 — PR Preview Uses Canary

During Phase 2 (PR preview), after the preview namespace is created:
```bash
kubectl get rollouts -n student-app-pr-<N>
# Expected: fastapi-app and frontend-app both Healthy
# Confirm canary ran:
kubectl describe rollout fastapi-app -n student-app-pr-<N> | grep "RolloutCompleted"
```

### T7 — Rollout Restart in check_and_fix_coredns

Verify the patched function handles Rollout resources (automatic during pipeline if CoreDNS IP is stale, or simulate):
```bash
# Simulate stale IP detection by checking the function manually:
grep -A15 "Restarting fastapi-app Rollout" scripts/cicd-pipeline-test.sh
# Should show: kubectl patch rollout ... restartAt

# If stale IP scenario fires, confirm pods restart:
kubectl get pods -n student-app-dev -l app=fastapi-app --watch
# Should see: old pods Terminating, new pods Creating → Running
```

### T8 — Rollout History

```bash
kubectl rollout history rollout/fastapi-app -n student-app-dev
# Expected: at least revision 1 (initial deploy) + revision 2 (canary deploy)
```

### T9 — Full Pipeline Test Result

The definitive acceptance test — `cicd-pipeline-test.sh --skip-setup` must complete all phases:

| Phase | Environment | Target | Expected Result |
|-------|-------------|--------|-----------------|
| Phase 1 | dev | `dev.student.local:8080` | Rollouts Healthy, 54 E2E tests pass |
| Phase 2 | PR preview | `pr-N.student.local:8080` | Rollouts Healthy, 54 E2E tests pass, namespace deleted post-close |
| Phase 3 | prod | `prod.student.local:8080` | Rollouts Healthy, 54 E2E tests pass |

---

## Verification Checklist

- [ ] `kubectl get pods -n argo-rollouts` — controller Running
- [ ] `argocd version` — v3.3.1 confirmed
- [ ] `kubectl get rollout -n student-app-dev` — fastapi-app + frontend-app Healthy
- [ ] `kubectl get rollout -n student-app-prod` — fastapi-app + frontend-app Healthy
- [ ] `argocd app get student-app-dev` — Synced + Healthy
- [ ] `argocd app get student-app-prod` — Synced + Healthy
- [ ] Canary steps visible in `kubectl describe rollout fastapi-app -n student-app-dev`
- [ ] Phase 1 E2E: 54 tests pass
- [ ] Phase 2 E2E: 54 tests pass + preview namespace deleted after PR close
- [ ] Phase 3 E2E: 54 tests pass
- [ ] `argocd app list` — no orphaned preview apps
