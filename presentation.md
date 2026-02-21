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

## 2. ArgoCD — Application Status

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

## 3. Argo Rollouts — Canary Deployment Strategy

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

## 4. Application — Development Environment

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

## 5. Application — Production Environment

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

## 6. End-to-End Test Results

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

## 7. Deployment Pipeline Flow

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

## 8. Key Benefits

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

## 9. Infrastructure Summary

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

## 10. Next Steps (Optional Enhancements)

| Enhancement | Description | Effort |
|-------------|-------------|--------|
| Argo Rollouts Analysis | Add automated metrics analysis during canary | Medium |
| Multi-cluster | Promote to a separate production cluster | High |
| Slack notifications | Alert on rollout start/complete/abort | Low |
| ArgoCD Image Updater | Auto-detect new images without Jenkins | Medium |
| Istio/service mesh | HTTP-level traffic splitting (vs replica-based) | High |

---

*Generated: February 20, 2026 | Branch: `argo-rollout` | Commit: `e390745`*
