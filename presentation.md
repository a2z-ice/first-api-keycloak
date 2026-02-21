# Student Management System — GitOps Canary Deployment
## Technical Presentation: ArgoCD + Argo Rollouts Integration

**Date:** February 20, 2026
**Project:** Student Management System (OAuth2.1 + Keycloak)
**Scope:** Zero-downtime canary deployments via ArgoCD GitOps pipeline

---

## Executive Summary

This document demonstrates the successful implementation of a **production-grade GitOps CI/CD pipeline** with **automated canary deployments** for the Student Management System. The system deploys safely to Kubernetes using Argo Rollouts, which sends 50% of traffic to the new version first — verifying stability before completing the rollout. All 45 end-to-end tests pass in both development and production environments.

### Key Outcomes

| Metric | Result |
|--------|--------|
| Deployment strategy | Canary (50% → 100% traffic shift) |
| Dev E2E test pass rate | **45 / 45 (100%)** |
| Prod E2E test pass rate | **45 / 45 (100%)** |
| Downtime during deployment | **Zero** |
| Rollback capability | Automatic (ArgoCD) |
| Environments managed | Dev, Production, PR Preview |

---

## 1. Architecture Overview

The system uses a **GitOps** model: all deployments are driven by Git commits, not manual commands. ArgoCD continuously monitors GitHub and applies any changes to Kubernetes automatically.

```
Developer → Git Push → GitHub
                           ↓
                      ArgoCD watches
                      gitops/overlays/
                           ↓
               Kubernetes Cluster (Kind)
               ├── student-app-dev
               │   ├── fastapi-app   (Rollout — canary)
               │   └── frontend-app  (Rollout — canary)
               └── student-app-prod
                   ├── fastapi-app   (Rollout — canary)
                   └── frontend-app  (Rollout — canary)
```

### Technology Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Container Orchestration | Kubernetes (Kind) | v1.35 |
| GitOps Controller | ArgoCD | v3.0.5 |
| Canary Deployments | Argo Rollouts | v1.8.4 |
| Identity Provider | Keycloak | 26.5.3 |
| Backend API | FastAPI (Python) | Latest |
| Frontend | React 19 + TypeScript | Latest |

---

## 2. Jenkins — CI Automation (The Build Engine)

Jenkins is the **Continuous Integration** layer. It is responsible for everything that happens *before* Kubernetes: compiling code, building Docker images, pushing them to the registry, and updating the GitOps overlay. ArgoCD then picks up those changes automatically.

Jenkins is **NOT** responsible for deploying directly to Kubernetes — that is ArgoCD's job. Jenkins only pushes to Git.

```
Developer
    ↓  git push
GitHub
    ↓  webhook
Jenkins                ← THIS IS JENKINS' ROLE
    ↓  docker build + push
    ↓  git push (overlay image tag)
GitHub (gitops/overlays/dev/)
    ↓  ArgoCD watches
Kubernetes (canary rollout via Argo Rollouts)
```

### Three Pipeline Jobs

| Job | Jenkinsfile | Triggered By | Purpose |
|-----|-------------|-------------|---------|
| `student-app-dev` | `Jenkinsfile.dev` | Manual / push to `cicd` | Build + deploy to dev + E2E test |
| `student-app-pr-preview` | `Jenkinsfile.pr-preview` | PR opened with `preview` label | Ephemeral test environment per PR |
| `student-app-prod` | `Jenkinsfile.prod` | Push to `main` (PR merge) | Promote dev image to production |

### 2.1 Jenkins Dashboard — Three Pipeline Jobs

![Jenkins Dashboard](docs/screenshots/20-jenkins-dashboard.png)

**What this shows:**
- Jenkins 2.541.2 running at `http://localhost:8090`
- Three pipeline jobs: `student-app-dev`, `student-app-pr-preview`, `student-app-prod`
- `student-app-dev` has build #1 (failed due to Groovy backtick syntax — fixed in the actual cicd branch run via `cicd-pipeline-test.sh`)
- `student-app-pr-preview` and `student-app-prod` await their triggers (webhook or manual)

---

### 2.2 Dev Pipeline Job

![Jenkins Dev Job](docs/screenshots/21-jenkins-dev-job.png)

**What this shows:**
- `student-app-dev` job configured with `Jenkinsfile.dev` from the `cicd` branch
- Pipeline source: `https://github.com/a2z-ice/first-api-keycloak.git`
- The job runs the full dev pipeline: build → push → deploy → E2E tests → open PR

---

### 2.3 PR Preview Pipeline Job

![Jenkins PR Preview Job](docs/screenshots/22-jenkins-pr-preview-job.png)

**What this shows:**
- `student-app-pr-preview` job — triggered when a GitHub PR gets the `preview` label
- Creates a fully isolated Kubernetes namespace `student-app-pr-{N}` with its own DB, Redis, and app instances
- Runs 45 E2E tests against the PR's specific code before it reaches main
- When tests pass, it **merges the PR** automatically

---

### 2.4 Prod Pipeline Job

![Jenkins Prod Job](docs/screenshots/23-jenkins-prod-job.png)

**What this shows:**
- `student-app-prod` job — triggered automatically when main branch changes (PR merge)
- **Does NOT rebuild Docker images** — reuses the same image tag that passed dev E2E tests
- Updates `gitops/overlays/prod/kustomization.yaml` → pushes to `main` → ArgoCD auto-syncs production

---

### 2.5 Jenkins Credentials (Stored Secrets)

![Jenkins Credentials](docs/screenshots/24-jenkins-credentials.png)

**What this shows:**
- `ARGOCD_PASSWORD` — ArgoCD admin password used to authenticate CLI commands (`argocd app wait`)
- `GITHUB_TOKEN` — GitHub PAT used for `gh pr create`, `gh pr merge`, and labeling PRs
- Credentials stored securely in Jenkins, never hardcoded in Jenkinsfiles
- Jenkins injects them at build time via `credentials()` binding

---

### 2.6 Dev Pipeline Stages (All 8 Stages)

![Dev Pipeline Stages](docs/screenshots/25-jenkins-pipeline-dev-stages.png)

**Stage-by-stage explanation:**

| # | Stage | What Jenkins does |
|---|-------|------------------|
| 1 | **Checkout** | `git clone` the `cicd` branch |
| 2 | **Build Images** | `docker build` FastAPI and React/Nginx images |
| 3 | **Push Images** | Push `dev-<sha8>` tagged images to `localhost:5001` registry |
| 4 | **Update Overlay** | Edit `gitops/overlays/dev/kustomization.yaml` with new tag → commit → push to `dev` branch |
| 5 | **ArgoCD Sync** | `argocd app wait student-app-dev --health --timeout 300` — waits for canary to complete |
| 6 | **Seed DB** | `kubectl exec` inline Python to create departments + student records |
| 7 | **E2E Tests** | `npx playwright test` — 45 tests against `dev.student.local:8080` |
| 8 | **Open PR** | `gh pr create cicd → main` — triggers PR preview pipeline |

---

### 2.7 PR Preview Pipeline Stages (All 10 Stages)

![PR Preview Pipeline Stages](docs/screenshots/26-jenkins-pipeline-preview-stages.png)

**This pipeline is the most complex — it creates a full isolated environment:**

| # | Stage | What Jenkins does |
|---|-------|------------------|
| 1 | **Checkout** | Clone the PR branch |
| 2 | **Build Images** | Build both images with `pr-{N}-<sha8>` tags |
| 3 | **Push Images** | Push to registry |
| 4 | **Label PR** | `POST /repos/.../issues/{N}/labels` → adds `preview` label → ArgoCD ApplicationSet detects it |
| 5 | **Wait Namespace** | Polls until `student-app-pr-{N}` namespace exists (ArgoCD created it) |
| 6 | **ArgoCD Sync** | Wait for PR app to be Healthy (canary rollout) |
| 7 | **Copy TLS Secret** | `kubectl` copies `keycloak-tls` secret into PR namespace |
| 8 | **Seed DB** | Seeds test data into the PR-specific database |
| 9 | **E2E Tests** | 45 tests against `pr-{N}.student.local:8080` |
| 10 | **Merge PR** | `gh pr merge` → pushes to `main` → triggers production pipeline |

---

### 2.8 Production Pipeline Stages (All 6 Stages)

![Prod Pipeline Stages](docs/screenshots/27-jenkins-pipeline-prod-stages.png)

**Production is the simplest pipeline — no rebuild:**

| # | Stage | What Jenkins does |
|---|-------|------------------|
| 1 | **Checkout** | Clone `main` branch |
| 2 | **Reuse Dev Tag** | Read `IMAGE_TAG` from `gitops/overlays/dev/kustomization.yaml` — same image as dev |
| 3 | **Update Overlay** | Write same tag to `gitops/overlays/prod/kustomization.yaml` → push to `main` |
| 4 | **ArgoCD Sync** | Wait for `student-app-prod` to be Healthy (canary rollout in production) |
| 5 | **Seed DB** | Seed production database |
| 6 | **E2E Tests** | 45 tests against `prod.student.local:8080` — confirms production is working |

---

## 3. ArgoCD — Application Status

ArgoCD manages all environments from a single control plane. Both **development** and **production** environments are `Healthy` and `Synced`.

### 2.1 Application List — Both Environments Healthy

![ArgoCD Application List](docs/screenshots/01-argocd-app-list.png)

**What this shows:**
- `student-app-dev` — Healthy ✅ | Synced ✅ | Watching `dev` branch
- `student-app-prod` — Healthy ✅ | Synced ✅ | Watching `main` branch
- Last sync: 5 hours ago (automated, no manual intervention)
- Both apps track the same GitHub repository, different overlays

---

### 2.2 Development Environment — Resource Tree

![ArgoCD Dev Detail](docs/screenshots/02-argocd-dev-detail.png)

**What this shows:**
- App Health: **Healthy** (green heart icon)
- Sync Status: **Synced** to `dev` branch commit `e390745`
- Last sync succeeded: Feb 20 2026 16:54:55 (automated)
- 13 resources Synced, 19 resources Healthy
- Resource tree shows: ConfigMaps, Secrets, Services, Rollouts, Ingress all healthy
- Commit message: "feat: upgrade ArgoCD v3.0.5→v3.3.1 + install Argo Rollouts"

---

### 2.3 Full Resource Tree (Dev Environment)

![ArgoCD Dev Resource Tree](docs/screenshots/03-argocd-dev-resource-tree.png)

**What this shows:**
- Complete Kubernetes resource hierarchy managed by ArgoCD
- All resources in `student-app-dev` namespace are **Synced** and **Healthy**
- Rollout resources (`fastapi-app`, `frontend-app`) replacing old Deployments
- ArgoCD tracks every resource — ConfigMaps, Secrets, Services, Ingress, Rollouts

---

### 2.4 Production Environment Detail

![ArgoCD Prod Detail](docs/screenshots/04-argocd-prod-detail.png)

**What this shows:**
- Production is identically healthy — Synced to `main` branch
- Same Argo Rollouts canary strategy applied to production
- Promotion from dev to prod is a single Git push (`cicd → main`)
- No separate deployment scripts — Git is the source of truth

---

### 2.5 ArgoCD Resource Inspector

![ArgoCD Resource Panel](docs/screenshots/05-argocd-rollout-resource-panel.png)

**What this shows:**
- ArgoCD's resource detail view — live manifest browser
- Shows the actual Kubernetes YAML currently applied in the cluster
- Configuration visible: `KEYCLOAK_URL`, `DATABASE_URL`, `APP_URL`
- ArgoCD tracks drift: any manual change to the cluster is detected and flagged as OutOfSync

---

## 4. Argo Rollouts — Canary Deployment Strategy

Argo Rollouts replaces Kubernetes `Deployment` resources with `Rollout` resources that implement advanced deployment strategies. The canary strategy routes a portion of real traffic to the new version before full rollout.

### 3.1 Canary Steps Configured

![Rollout Canary Strategy](docs/screenshots/18-kubectl-rollout-describe-canary.png)

**FastAPI Backend canary steps:**

| Step | Action | Duration |
|------|--------|---------|
| 1 | Route 50% of traffic to new version | — |
| 2 | Pause | 15 seconds |
| 3 | Route 100% of traffic to new version | — |
| 4 | Pause | 10 seconds |
| 5 | Complete | — |

**What this means in practice:**
- With 2 replicas: 1 pod runs new code, 1 pod runs old code
- For 15 seconds, real users hit both versions — Rollouts checks health
- If the new pod fails health checks, the rollout **automatically aborts** and routes back to the stable version
- Total canary window: ~25 seconds of pauses + pod startup time

---

### 3.2 Rollouts Running in Dev Environment

![Kubectl Rollouts Dev](docs/screenshots/14-kubectl-rollouts-dev.png)

**What this shows:**
- Both `fastapi-app` and `frontend-app` are Argo Rollouts in dev
- DESIRED: 2, CURRENT: 2, UP-TO-DATE: 2, AVAILABLE: 2
- Running for 4h56m — stable after initial canary deployment

---

### 3.3 Rollouts Running in Production

![Kubectl Rollouts Prod](docs/screenshots/15-kubectl-rollouts-prod.png)

**What this shows:**
- Production mirrors dev — identical Rollout configuration
- Both Rollouts fully available (2/2 replicas)
- Production promoted from dev after all E2E tests passed

---

### 3.4 Argo Rollouts Controller

![Argo Rollouts Controller](docs/screenshots/17-kubectl-argo-rollouts-controller.png)

**What this shows:**
- Argo Rollouts controller running in dedicated `argo-rollouts` namespace
- 1/1 Ready, Status: Running, 0 restarts — stable controller
- The controller watches all Rollout CRDs across namespaces and manages canary progression

---

### 3.5 ArgoCD Application Status (All Environments)

![ArgoCD Apps kubectl](docs/screenshots/16-kubectl-argocd-apps.png)

**What this shows:**
- `student-app-dev` — STATUS: Synced, HEALTH: Healthy
- `student-app-prod` — STATUS: Synced, HEALTH: Healthy
- ArgoCD natively understands Rollout health (no plugins required)

---

### 3.6 Custom Resource Definitions Installed

![Rollout CRDs](docs/screenshots/19-rollout-crds.png)

**What this shows:**
- All Argo Rollouts CRDs installed and registered in Kubernetes
- `rollouts.argoproj.io` — the main Rollout resource
- `analysisruns.argoproj.io`, `analysistemplates.argoproj.io` — automated analysis
- `experiments.argoproj.io` — A/B testing support (available but not yet used)

---

## 5. Application — Development Environment

The Student Management System is a full-stack web application secured with OAuth2.1 and Keycloak. Access is role-based: admins see everything, staff see students but cannot edit, students see only their own record.

### 4.1 Authentication — Keycloak Login Page

![Keycloak Login](docs/screenshots/06-keycloak-login-page.png)

**What this shows:**
- Standard Keycloak login flow (OAuth2.1 + PKCE)
- Users authenticate against Keycloak — credentials never reach the application server
- After login, Keycloak redirects back to the app with a secure session token

---

### 4.2 Admin Dashboard

![Dev Dashboard Admin](docs/screenshots/07-dev-dashboard-admin.png)

**What this shows:**
- Admin user (`admin-user`) sees full dashboard
- Role badge displayed in navbar: `admin`
- Quick access to Students and Departments management
- Welcome message personalised with Keycloak user name

---

### 4.3 Student Management (Admin View — Full Access)

![Dev Students Admin](docs/screenshots/08-dev-students-list-admin.png)

**What this shows:**
- Admin sees ALL students across all departments
- Add Student and Edit buttons visible (admin-only controls)
- Data filtered server-side based on Keycloak role claims

---

### 4.4 Department Management

![Dev Departments](docs/screenshots/09-dev-departments-list.png)

**What this shows:**
- Department listing with admin controls
- All departments visible to all authenticated users
- Only admins see Create/Edit controls

---

### 4.5 Dark Mode Support

![Dark Mode](docs/screenshots/10-dev-dashboard-dark-mode.png)

**What this shows:**
- Full dark mode toggle (persisted in localStorage)
- Consistent styling across all pages in dark theme

---

### 4.6 Student Role — Limited View

![Student Role View](docs/screenshots/11-dev-students-list-student-role.png)

**What this shows:**
- Student user sees ONLY their own record (server-enforced, not just hidden in UI)
- No Add Student or Edit buttons visible
- RBAC enforced at both API and UI layers

---

## 6. Application — Production Environment

Production runs the same code promoted from dev after all E2E tests pass.

### 5.1 Production Dashboard

![Prod Dashboard](docs/screenshots/12-prod-dashboard-admin.png)

**What this shows:**
- Production environment identical to dev (same Docker image tag)
- Separate Keycloak client (`student-app-prod`) for security isolation
- Admin user logged in and seeing full dashboard

---

### 5.2 Production Students List

![Prod Students](docs/screenshots/13-prod-students-list.png)

**What this shows:**
- Student data seeded in production environment
- Full admin view in production
- Application fully functional post canary deployment

---

## 7. End-to-End Test Results

All 45 automated Playwright tests pass in both environments after canary deployment.

### 6.1 Test Coverage

| Test Suite | Tests | Coverage |
|------------|-------|---------|
| Authentication | 6 | Login, logout, session, redirect |
| Student RBAC | 9 | Admin/staff/student role access |
| Student CRUD | 5 | Create, view, edit operations |
| Department CRUD | 5 | Create, view, edit operations |
| Navigation | 4 | Navbar, routing, card links |
| Form Validation | 3 | Required fields, error messages |
| Error Handling | 3 | 404, 403, invalid records |
| Dark Mode | 2 | Toggle, persistence |
| **Total** | **45** | **100% pass** |

### 6.2 Test Results Summary

```
Dev Environment:   45 passed (18.2s)   ✅
Production:        45 passed (15.9s)   ✅
```

Tests run against the live deployed application (not mocks) and verify the complete stack: React frontend → Nginx proxy → FastAPI → PostgreSQL → Keycloak OAuth2.1.

---

## 8. Deployment Pipeline Flow

```
1. Developer pushes code to cicd branch
        ↓
2. Jenkins builds Docker images
   (fastapi-student-app:dev-<sha8>)
   (frontend-student-app:dev-<sha8>)
        ↓
3. Jenkins pushes images to local registry
        ↓
4. Jenkins updates gitops/overlays/dev/
   kustomization.yaml with new image tag
        ↓
5. ArgoCD detects change on dev branch
   → Syncs resources → Argo Rollouts runs canary
        ↓
6. Canary: 50% traffic → new pods (15s)
           100% traffic → new pods (10s)
        ↓
7. Jenkins runs 45 Playwright E2E tests
        ↓
8. [Pass] Jenkins opens PR to main
9. Jenkins promotes: pushes to prod overlay
        ↓
10. ArgoCD syncs production → same canary flow
        ↓
11. Jenkins runs 45 E2E tests on production
```

### Deployment Safety Features

| Feature | How It Works |
|---------|-------------|
| Canary traffic split | 50% new / 50% old — real users test both |
| Auto-abort on failure | Rollout health check fails → reverts to stable |
| Git-based rollback | `git revert` + push → ArgoCD syncs old state |
| Zero-downtime | maxUnavailable: 0 — old pods stay up during rollout |
| Separate environments | Dev validated first, then promoted to prod |
| E2E gate | Tests must pass before production promotion |

---

## 9. Key Benefits

### For Operations
- **No manual deployments** — every change goes through Git
- **Audit trail** — every deployment is a Git commit with author and message
- **Instant rollback** — revert any Git commit to restore previous state
- **Visibility** — ArgoCD dashboard shows real-time status of every resource

### For Development
- **PR Preview environments** — every pull request gets its own live environment
- **Fast feedback** — E2E tests run automatically after each deployment
- **Safe experimentation** — canary strategy limits blast radius of bad deployments

### For the Business
- **Zero downtime** — users are never interrupted during deployments
- **Risk reduction** — bad deployments affect at most 50% of traffic for 25 seconds
- **Compliance** — full audit log of who deployed what and when

---

## 10. Infrastructure Summary

```
Kubernetes Cluster (Kind — local)
├── argo-rollouts/         ← Argo Rollouts controller
├── argocd/                ← ArgoCD server + UI (port 30080/30081)
├── keycloak/              ← Keycloak 3-replica StatefulSet (HTTPS)
├── student-app-dev/       ← Development environment
│   ├── fastapi-app        Rollout (2 replicas, canary)
│   ├── frontend-app       Rollout (2 replicas, canary)
│   ├── app-postgresql     PostgreSQL for dev data
│   └── redis              Session storage
└── student-app-prod/      ← Production environment
    ├── fastapi-app        Rollout (2 replicas, canary)
    ├── frontend-app       Rollout (2 replicas, canary)
    ├── app-postgresql     PostgreSQL for prod data
    └── redis              Session storage
```

---

## 11. Next Steps (Optional Enhancements)

| Enhancement | Description | Effort |
|-------------|-------------|--------|
| Argo Rollouts Analysis | Add automated metrics analysis during canary | Medium |
| Multi-cluster | Promote to a separate production cluster | High |
| Slack notifications | Alert on rollout start/complete/abort | Low |
| ArgoCD Image Updater | Auto-detect new images without Jenkins | Medium |
| Istio/service mesh | HTTP-level traffic splitting (vs replica-based) | High |

---

*Generated: February 20, 2026 | Branch: `argo-rollout` | Commit: `e390745`*
