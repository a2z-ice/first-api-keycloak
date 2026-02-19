# Plan 5: ArgoCD GitOps Multi-Environment Pipeline

> **Plan Name**: argocd-gitops-multi-env-pipeline
> **Created**: 2026-02-18
> **Status**: Planned

---

# ArgoCD GitOps Multi-Environment Pipeline

## Context

The project currently deploys to a single Kind cluster namespace (`keycloak`) using manual bash scripts and `imagePullPolicy: Never`. The goal is to introduce ArgoCD-driven GitOps with Jenkins CI, a local Docker registry, and three environment tiers:

- **PR Preview** (`student-app-pr-{N}`) — ephemeral, created by ArgoCD PullRequest Generator per labeled PR, destroyed when PR closes
- **Dev** (`student-app-dev`) — permanent, updated on merge to `dev` branch
- **Prod** (`student-app-prod`) — permanent, promoted from dev after E2E pass

Git remote: `git@github.com:a2z-ice/first-api-keycloak.git`
ArgoCD version: **v3.3.1** (latest stable as of 2026-02)

---

## ArgoCD Features Used

### Feature 1: ApplicationSet with List Generator (Dev + Prod)

`ApplicationSet` (`gitops/argocd/applicationsets/environments.yaml`) uses the **List generator** to manage the two static environments (dev and prod) from a single ArgoCD resource. For each entry in the list, ArgoCD creates one `Application` that watches a branch of the GitHub repo and auto-syncs.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: student-app-environments
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
            namespace: student-app-dev
            branch: dev
            host: dev.student.local
          - env: prod
            namespace: student-app-prod
            branch: main
            host: prod.student.local
  template:
    metadata:
      name: 'student-app-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/a2z-ice/first-api-keycloak.git
        targetRevision: '{{branch}}'
        path: 'gitops/environments/overlays/{{env}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions: [CreateNamespace=true]
```

How sync is triggered: Jenkins updates `gitops/environments/overlays/{env}/kustomization.yaml` (image tag field), commits, and pushes to the `dev` or `main` branch. ArgoCD polls GitHub every 3 minutes (or via webhook) and auto-syncs.

### Feature 2: ApplicationSet with Pull Request Generator (PR Previews)

`ApplicationSet` (`gitops/argocd/applicationsets/pr-preview.yaml`) uses the **Pull Request generator** — the core ArgoCD feature for preview environments. It watches the GitHub repo for open PRs that have a specific label (`preview`). For each matching PR, ArgoCD automatically creates one `Application`. When the PR is closed or the label is removed, ArgoCD deletes the `Application` (cascading, pruning all K8s resources in the preview namespace).

The PR generator provides these template variables:
- `{{number}}` — PR number (e.g., `42`)
- `{{head_sha}}` — full commit SHA
- `{{head_short_sha}}` — 8-char short SHA
- `{{branch}}` — source branch name
- `{{branch_slug}}` — DNS-safe branch name

The ApplicationSet template uses the `kustomize.images` and `kustomize.patches` fields to inject PR-specific values (image tag, namespace, APP_URL, Keycloak client ID, Ingress hostname) without needing a separate git-committed overlay per PR:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: student-app-pr-preview
  namespace: argocd
spec:
  generators:
    - pullRequest:
        github:
          owner: a2z-ice
          repo: first-api-keycloak
          tokenRef:
            secretName: github-token
            key: token
          labels:
            - preview           # Only PRs labeled 'preview' get an environment
        requeueAfterSeconds: 30  # Poll GitHub every 30s for PR changes
  template:
    metadata:
      name: 'student-app-pr-{{number}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/a2z-ice/first-api-keycloak.git
        targetRevision: '{{head_sha}}'          # Exact commit on the PR head
        path: gitops/environments/overlays/preview   # Single shared preview overlay
        kustomize:
          namespace: 'student-app-pr-{{number}}'
          images:
            - 'fastapi-student-app=localhost:5001/fastapi-student-app:pr-{{number}}-{{head_short_sha}}'
            - 'frontend-student-app=localhost:5001/frontend-student-app:pr-{{number}}-{{head_short_sha}}'
          patches:
            # Patch ConfigMap: APP_URL, FRONTEND_URL, KEYCLOAK_CLIENT_ID
            - target:
                kind: ConfigMap
                name: fastapi-app-config
              patch: |
                - op: replace
                  path: /data/APP_URL
                  value: http://pr-{{number}}.student.local:8080
                - op: replace
                  path: /data/FRONTEND_URL
                  value: http://pr-{{number}}.student.local:8080
                - op: replace
                  path: /data/KEYCLOAK_CLIENT_ID
                  value: student-app-pr-{{number}}
            # Patch Ingress: hostname
            - target:
                kind: Ingress
                name: frontend-ingress
              patch: |
                - op: replace
                  path: /spec/rules/0/host
                  value: pr-{{number}}.student.local
      destination:
        server: https://kubernetes.default.svc
        namespace: 'student-app-pr-{{number}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions: [CreateNamespace=true]
```

---

## Full Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Developer Workstation                        │
│                                                                      │
│  git push → GitHub ──webhook──→ Jenkins (localhost:8090)             │
│                                                                      │
│  Jenkins does:                                                       │
│  1. docker build + push → Local Registry (localhost:5001)            │
│  2. gh pr edit --add-label preview  ← triggers ArgoCD PR Generator  │
│     OR: git push overlay commit  ← triggers ArgoCD List Generator   │
│  3. argocd app wait ... (wait for ArgoCD to sync and be Healthy)    │
│  4. Seed DB, register Keycloak client, add /etc/hosts               │
│  5. npx playwright test (E2E)                                        │
│  6. On pass: gh pr merge (PR), or gh pr create (dev→prod)           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │     Kind Cluster               │
                    │                                │
                    │  ┌─────────────────────────┐  │
                    │  │  argocd namespace        │  │
                    │  │                          │  │
                    │  │  ApplicationSet:          │  │
                    │  │  student-app-environments │  │
                    │  │  (List Generator)         │  │
                    │  │  → Creates:               │  │
                    │  │    Application: dev       │  │
                    │  │    Application: prod      │  │
                    │  │                          │  │
                    │  │  ApplicationSet:          │  │
                    │  │  student-app-pr-preview   │  │
                    │  │  (PullRequest Generator)  │  │
                    │  │  → Creates per PR:        │  │
                    │  │    Application: pr-{N}    │  │
                    │  └─────────────────────────┘  │
                    │                                │
                    │  ┌────────────────────────┐   │
                    │  │  student-app-dev ns     │   │
                    │  │  (watched: dev branch)  │   │
                    │  │  fastapi + frontend      │   │
                    │  │  + pg + redis            │   │
                    │  └────────────────────────┘   │
                    │                                │
                    │  ┌────────────────────────┐   │
                    │  │  student-app-prod ns    │   │
                    │  │  (watched: main branch) │   │
                    │  └────────────────────────┘   │
                    │                                │
                    │  ┌────────────────────────┐   │
                    │  │  student-app-pr-{N} ns  │   │
                    │  │  (ephemeral, per PR)    │   │
                    │  │  Auto-deleted on merge  │   │
                    │  └────────────────────────┘   │
                    │                                │
                    │  ┌────────────────────────┐   │
                    │  │  ingress-nginx ns       │   │
                    │  │  port 80→host:8080      │   │
                    │  │  dev.student.local      │   │
                    │  │  prod.student.local     │   │
                    │  │  pr-{N}.student.local   │   │
                    │  └────────────────────────┘   │
                    │                                │
                    │  ┌────────────────────────┐   │
                    │  │  keycloak ns (existing) │   │
                    │  │  Shared Keycloak        │   │
                    │  │  Per-env clients:       │   │
                    │  │  student-app-dev        │   │
                    │  │  student-app-prod       │   │
                    │  │  student-app-pr-{N}     │   │
                    │  └────────────────────────┘   │
                    └───────────────────────────────┘
```

---

## Pipeline Workflows

### Pipeline 1: PR Preview (`jenkins/pipelines/Jenkinsfile.pr-preview`)

Triggered by: GitHub webhook on `PR opened` or `synchronize` (new commit pushed to PR branch). Jenkins detects PR branches via Multibranch Pipeline.

```
Stage 1 — Build Images
  docker build -t localhost:5001/fastapi-student-app:pr-{N}-{SHA} ./backend
  docker build -t localhost:5001/frontend-student-app:pr-{N}-{SHA} ./frontend

Stage 2 — Push Images to Local Registry
  docker push localhost:5001/fastapi-student-app:pr-{N}-{SHA}
  docker push localhost:5001/frontend-student-app:pr-{N}-{SHA}

Stage 3 — Trigger ArgoCD PR Preview (via GitHub label)
  gh pr edit {N} --add-label preview
  → ArgoCD PullRequest Generator detects PR with 'preview' label within 30s
  → ArgoCD creates Application 'student-app-pr-{N}'
  → ArgoCD applies: gitops/environments/overlays/preview + kustomize image/patch overrides from ApplicationSet template
  → ArgoCD creates namespace 'student-app-pr-{N}' + deploys all resources

Stage 4 — Copy TLS Secret into Preview Namespace
  kubectl get secret keycloak-tls -n keycloak -o yaml | \
    sed 's/namespace: keycloak/namespace: student-app-pr-{N}/' | kubectl apply -f -

Stage 5 — Wait for ArgoCD Sync
  argocd app wait student-app-pr-{N} --health --sync --timeout 180

Stage 6 — Register Keycloak Client for PR env
  Create Keycloak client 'student-app-pr-{N}' with:
    redirectUri: http://pr-{N}.student.local:8080/api/auth/callback
    webOrigins: http://pr-{N}.student.local:8080
  (via curl to Keycloak admin REST API, reusing pattern from realm-setup.sh)

Stage 7 — Add /etc/hosts Entry
  echo "127.0.0.1 pr-{N}.student.local" | sudo tee -a /etc/hosts

Stage 8 — Seed Database
  POD=$(kubectl get pod -n student-app-pr-{N} -l app=fastapi-app -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n student-app-pr-{N} $POD -- python /app/scripts/create-test-data.py

Stage 9 — Run E2E Tests
  cd frontend && APP_URL=http://pr-{N}.student.local:8080 npx playwright test --reporter=html

POST SUCCESS:
  - gh pr merge {N} --merge --admin   (auto-merge closes PR)
  → ArgoCD PullRequest Generator detects PR closed → deletes Application 'student-app-pr-{N}'
  → ArgoCD prune cascade → deletes all K8s resources in student-app-pr-{N}
  → ArgoCD deletes namespace 'student-app-pr-{N}'
  - Delete Keycloak client 'student-app-pr-{N}' via admin API
  - Remove /etc/hosts entry for pr-{N}.student.local

POST FAILURE:
  - Archive playwright-report/ as Jenkins artifact
  - Leave preview env running for investigation (ArgoCD keeps it alive while PR is open)
```

### Pipeline 2: Dev Deploy (`jenkins/pipelines/Jenkinsfile.dev`)

Triggered by: Push to `dev` branch (from merged PR).

```
Stage 1 — Build Images
  docker build -t localhost:5001/fastapi-student-app:dev-{SHA} ./backend
  docker build -t localhost:5001/frontend-student-app:dev-{SHA} ./frontend

Stage 2 — Push to Registry

Stage 3 — Update Dev Overlay (trigger ArgoCD via git)
  Update gitops/environments/overlays/dev/kustomization.yaml:
    images[fastapi-student-app].newTag: dev-{SHA}
    images[frontend-student-app].newTag: dev-{SHA}
  git commit -m "ci: update dev image tags to dev-{SHA}"
  git push origin dev
  → ArgoCD List Generator ApplicationSet 'student-app-environments' detects
    commit on 'dev' branch for Application 'student-app-dev'
  → ArgoCD auto-syncs student-app-dev

Stage 4 — Wait for ArgoCD Sync
  argocd app wait student-app-dev --health --sync --timeout 180

Stage 5 — Run E2E Tests
  cd frontend && APP_URL=http://dev.student.local:8080 npx playwright test

POST SUCCESS:
  gh pr create --base main --head dev --title "Promote dev→prod [dev-{SHA}]" \
    --body "Automated promotion after E2E pass on dev environment."
  (→ triggers Pipeline 3 when merged)

POST FAILURE:
  Jenkins build marked as failed; team investigates
```

### Pipeline 3: Prod Deploy (`jenkins/pipelines/Jenkinsfile.prod`)

Triggered by: Push to `main` branch (from merged dev→prod PR).

```
Stage 1 — Reuse Dev Images (no rebuild)
  Read image tag from gitops/environments/overlays/dev/kustomization.yaml
  PROD_TAG=$(the same dev-{SHA} tag that was validated in dev)

Stage 2 — Update Prod Overlay
  Update gitops/environments/overlays/prod/kustomization.yaml with PROD_TAG
  git commit -m "ci: promote {PROD_TAG} to prod"
  git push origin main
  → ArgoCD List Generator detects commit on 'main' branch for Application 'student-app-prod'
  → ArgoCD auto-syncs student-app-prod

Stage 3 — Wait for ArgoCD Sync
  argocd app wait student-app-prod --health --sync --timeout 180

Stage 4 — Run E2E Tests
  cd frontend && APP_URL=http://prod.student.local:8080 npx playwright test

POST SUCCESS/FAILURE: Jenkins build status + optional notification
```

---

## Files to Create

### A. GitOps — Kustomize Structure

```
gitops/
├── argocd/
│   ├── applicationsets/
│   │   ├── environments.yaml          # List Generator → dev + prod Applications
│   │   └── pr-preview.yaml           # PullRequest Generator → PR preview Applications
│   └── secrets/
│       └── github-token-secret.yaml  # ArgoCD secret to access GitHub for PR polling
└── environments/
    ├── base/
    │   ├── kustomization.yaml
    │   ├── fastapi/
    │   │   ├── deployment.yaml        # Generalized from keycloak/fastapi-app/app-deployment.yaml
    │   │   │                          #   - Remove namespace: keycloak
    │   │   │                          #   - Remove hostAliases (replaced by CoreDNS)
    │   │   │                          #   - Keep init-db container, TLS volume, probes
    │   │   ├── service.yaml
    │   │   ├── configmap.yaml         # Placeholder values (patched per env)
    │   │   └── secret.yaml
    │   ├── frontend/
    │   │   ├── deployment.yaml        # imagePullPolicy: Always (uses registry images)
    │   │   ├── service.yaml           # type: ClusterIP (NOT NodePort — Ingress handles routing)
    │   │   └── ingress.yaml           # Ingress resource (hostname patched per env)
    │   ├── postgresql/
    │   │   ├── deployment.yaml
    │   │   ├── service.yaml
    │   │   └── secret.yaml
    │   └── redis/
    │       ├── deployment.yaml
    │       └── service.yaml
    └── overlays/
        ├── dev/
        │   ├── kustomization.yaml     # images section updated by Jenkins (dev-{SHA} tags)
        │   ├── namespace.yaml         # namespace: student-app-dev
        │   └── patches/
        │       ├── config-patch.yaml  # APP_URL=dev.student.local:8080, client=student-app-dev
        │       └── ingress-patch.yaml # host: dev.student.local
        ├── prod/
        │   ├── kustomization.yaml
        │   ├── namespace.yaml         # namespace: student-app-prod
        │   └── patches/
        │       ├── config-patch.yaml  # APP_URL=prod.student.local:8080, client=student-app-prod
        │       └── ingress-patch.yaml # host: prod.student.local
        └── preview/                   # Single shared template — NO per-PR files needed
            ├── kustomization.yaml     # Base reference only; image/patch overrides come
            │                          # from ApplicationSet template (not git files)
            └── namespace.yaml         # namespace: placeholder (overridden by ApplicationSet)
```

**Key design note for `preview/` overlay:** There is only ONE `preview` overlay committed to git. The PR-specific values (image tag, APP_URL, Keycloak client, Ingress host) are injected by the ApplicationSet PullRequest Generator template via `kustomize.images` and `kustomize.patches`. No per-PR git commits are needed — ArgoCD handles the parameterization in-memory.

### B. Jenkins

```
jenkins/
├── Dockerfile                         # jenkins/lts + docker-ce-cli + kubectl + argocd-cli
│                                      # + Node.js 22 + Python 3 + gh CLI
├── docker-compose.yml                 # Jenkins service on kind Docker network
│                                      # Mounts: /var/run/docker.sock, kind-jenkins.config
└── pipelines/
    ├── Jenkinsfile.pr-preview         # PR Preview pipeline (declarative)
    ├── Jenkinsfile.dev                # Dev deploy pipeline
    └── Jenkinsfile.prod               # Prod deploy pipeline
```

### C. Setup Scripts

```
scripts/
├── setup-registry.sh                  # Start registry:2 on 'kind' network, port 5001
├── setup-argocd.sh                    # Install ArgoCD v3.3.1, configure NodePort,
│                                      # apply both ApplicationSets, configure CoreDNS
│                                      # override for idp.keycloak.com, install Nginx Ingress
├── setup-jenkins.sh                   # Generate kind-jenkins.config (node IP not 127.0.0.1),
│                                      # docker compose up jenkins
├── setup-keycloak-envs.sh             # Create dev + prod Keycloak clients
│                                      # (student-app-dev, student-app-prod)
└── setup-infrastructure.sh            # Master script: calls all 4 above in order
```

---

## Files to Modify

### `cluster/kind-config.yaml`
Add three sections:
1. `containerdConfigPatches` — mirror `localhost:5001` → `http://registry:5000` (Kind nodes pull from local registry)
2. `kubeadmConfigPatches` — label node with `ingress-ready=true` (required by Nginx Ingress)
3. New `extraPortMappings` entry: `containerPort: 80` → `hostPort: 8080` (Nginx Ingress)

Keep existing: port 31111 (Keycloak), 30000 (legacy), 32000.

### `setup.sh`
Add at the start: call `scripts/setup-registry.sh`.
Add at the end: call `scripts/setup-infrastructure.sh`.

### `.gitignore`
Add:
```
gitops/environments/overlays/pr-*/   # Never committed — ArgoCD parameterizes in-memory
jenkins/data/                        # Jenkins home volume data
```

### `CLAUDE.md`
Add new section: ArgoCD architecture, new environment URLs, new commands.

---

## CoreDNS Override (replaces `__NODE_IP__` hostAliases)

Setup script configures CoreDNS so all pods cluster-wide resolve `idp.keycloak.com`:

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
kubectl patch configmap coredns -n kube-system --patch "
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        hosts {
          $NODE_IP idp.keycloak.com
          fallthrough
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
"
kubectl rollout restart deployment coredns -n kube-system
```

This removes the need for `hostAliases` in any deployment manifest — all preview, dev, and prod pods automatically resolve `idp.keycloak.com` correctly.

---

## Implementation Order

1. `cluster/kind-config.yaml` — must be updated before cluster recreate
2. `scripts/setup-registry.sh`
3. `scripts/setup-argocd.sh` (includes CoreDNS patch, Nginx Ingress, ApplicationSet apply)
4. `scripts/setup-jenkins.sh`
5. `scripts/setup-keycloak-envs.sh`
6. `scripts/setup-infrastructure.sh`
7. `gitops/environments/base/` — 13 files (Kustomize base)
8. `gitops/environments/overlays/dev/` — 4 files
9. `gitops/environments/overlays/prod/` — 4 files
10. `gitops/environments/overlays/preview/` — 2 files (shared template, no per-PR files)
11. `gitops/argocd/applicationsets/environments.yaml` — List Generator ApplicationSet
12. `gitops/argocd/applicationsets/pr-preview.yaml` — PullRequest Generator ApplicationSet
13. `gitops/argocd/secrets/github-token-secret.yaml`
14. `jenkins/Dockerfile`
15. `jenkins/docker-compose.yml`
16. `jenkins/pipelines/Jenkinsfile.pr-preview`
17. `jenkins/pipelines/Jenkinsfile.dev`
18. `jenkins/pipelines/Jenkinsfile.prod`
19. Update `setup.sh`, `.gitignore`, `CLAUDE.md`

---

## Prerequisites and Access URLs

| Service | URL | Notes |
|---------|-----|-------|
| Jenkins UI | http://localhost:8090 | Initial password: `docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword` |
| Local Registry | http://localhost:5001/v2/_catalog | registry:2 container |
| ArgoCD UI | http://localhost:30080 | NodePort; password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| ArgoCD CLI | `argocd login localhost:30080 --insecure` | |
| Dev App | http://dev.student.local:8080 | Add to /etc/hosts: `127.0.0.1 dev.student.local` |
| Prod App | http://prod.student.local:8080 | Add to /etc/hosts: `127.0.0.1 prod.student.local` |
| PR Preview | http://pr-{N}.student.local:8080 | Added/removed dynamically by Jenkins |

**Jenkins credentials required:**
- `GITHUB_TOKEN` — for `gh pr merge`, `gh pr create`, label management, ArgoCD GitHub polling
- Git SSH key or HTTPS token — for pushing overlay commits to GitHub
- `ARGOCD_PASSWORD` — for `argocd` CLI commands in pipelines

---

## Verification Steps

1. **Registry**: `curl http://localhost:5001/v2/_catalog` → `{"repositories":[]}`
2. **ArgoCD apps exist**: `argocd app list` shows `student-app-dev` and `student-app-prod` as Synced/Healthy
3. **Ingress routing**: `curl -H "Host: dev.student.local" http://localhost:8080/api/health` → `{"status":"ok"}`
4. **Dev E2E**: `APP_URL=http://dev.student.local:8080 npx playwright test` — all pass
5. **PR Preview flow**:
   - Create a branch + PR on GitHub
   - Verify Jenkins Multibranch Pipeline detects it and runs `Jenkinsfile.pr-preview`
   - Verify `argocd app list` shows `student-app-pr-{N}` created
   - Verify `kubectl get ns | grep student-app-pr` shows namespace
   - Verify E2E runs and passes
   - Verify PR auto-merged and namespace deleted after pipeline completes
6. **Dev→Prod promotion**: After PR merges, verify `student-app-dev` syncs, E2E passes, and a new PR is opened against `main`
