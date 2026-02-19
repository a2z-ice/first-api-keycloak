# Skills & Technologies

This document catalogs all technologies, tools, patterns, and skills used in the Student Management System project.

---

## Technology Stack

### Backend

| Technology | Version | Purpose |
|-----------|---------|---------|
| Python | 3.12 | Runtime |
| FastAPI | 0.115.6 | JSON API framework |
| Uvicorn | 0.34.0 | ASGI server |
| Authlib | 1.4.1 | OAuth2.1 client (PKCE / Authorization Code) |
| SQLAlchemy | 2.0.37 | ORM (PostgreSQL + SQLite) |
| Pydantic Settings | 2.7.1 | Configuration management (.env) |
| httpx | 0.28.1 | Async HTTP client (Authlib transport) |
| itsdangerous | 2.2.0 | Signed session cookies |
| redis (async) | 5.0+ | Session store backend |
| psycopg2-binary | 2.9.10+ | PostgreSQL driver |

### Frontend

| Technology | Version | Purpose |
|-----------|---------|---------|
| React | 19.0.0 | UI framework |
| TypeScript | 5.7 | Type safety |
| Vite | 6.0.5 | Build tool + dev server |
| React Router | 7.1.1 | Client-side routing |
| Nginx | 1.27 (alpine) | Production static server + API reverse proxy |
| CSS Custom Properties | — | Theming (light/dark mode) |

### Testing

| Technology | Version | Purpose |
|-----------|---------|---------|
| Playwright | 1.49.1 | E2E browser testing (chromium) |
| @playwright/test | 1.49.1 | Test runner + assertions |
| HTML Reporter | built-in | Visual test report generation |

### Infrastructure

| Technology | Version | Purpose |
|-----------|---------|---------|
| Docker | — | Container builds (multi-stage) |
| Kind | — | Kubernetes-in-Docker local cluster |
| Kubernetes | 1.35 | Container orchestration |
| kubectl | — | Cluster management CLI |
| Keycloak | 26.5.3 | Identity provider (OAuth2.1 / OIDC) |
| PostgreSQL | — | Persistent storage (Keycloak DB + App DB) |
| Redis | — | Session storage (multi-replica consistency) |
| OpenSSL | — | Self-signed TLS certificate generation |

### CI/CD & GitOps

| Technology | Version | Purpose |
|-----------|---------|---------|
| ArgoCD | 3.0.5 | GitOps controller — syncs K8s state from git |
| ArgoCD ApplicationSet | — | Multi-app templating (List + PullRequest generators) |
| Kustomize | built-in | Overlay-based K8s manifest composition |
| Nginx Ingress Controller | — | Routes `*.student.local:8080` to correct namespaces |
| Docker Registry | registry:2 | Local image registry on port 5001 |
| Jenkins | LTS | CI pipeline (Multibranch, declarative Jenkinsfiles) |
| GitHub REST API | v3 | PR label management, SHA resolution |
| gh CLI | — | PR/issue management |

**Pipeline test script**: `scripts/cicd-pipeline-test.sh` — fully automated end-to-end test of all three pipeline phases. Verified working: 45/45 E2E tests pass in dev, PR preview, and prod. Key patterns inside:
- GITHUB_TOKEN retrieved from k8s secret (`argocd/github-token`) if not in environment
- ArgoCD app detection via `kubectl get application` (not `argocd app list`, which is unreliable in non-TTY)
- Seed script restores mutated student names before each E2E run
- No sudo calls — `/etc/hosts` management is printed as instructions for the user

### DevOps / Scripting

| Technology | Purpose |
|-----------|---------|
| Bash | Automation scripts (build, deploy, test, cleanup) |
| curl | Keycloak Admin REST API + GitHub REST API calls |
| sed | Template substitution in K8s manifests and kustomization.yaml |
| gh (GitHub CLI) | PR/issue management |

---

## GitOps / CI-CD Architecture Patterns

### ArgoCD ApplicationSet — List Generator (Dev + Prod)

Manages two permanent environments from a single resource. Watches different git branches:

```yaml
generators:
  - list:
      elements:
        - env: dev    # watches: dev branch → student-app-dev namespace
        - env: prod   # watches: main branch → student-app-prod namespace
```

Trigger: Jenkins (or manual) commits updated image tag to overlay `kustomization.yaml` and pushes to the watched branch. ArgoCD polls every 3 minutes and auto-syncs.

### ArgoCD ApplicationSet — PullRequest Generator (PR Previews)

Watches GitHub for open PRs with a specific label (`preview`). For each matching PR, creates one ephemeral `Application`. When the PR is closed, the Application and its namespace are automatically deleted (cascade prune).

Key variables available in PR Generator templates:
- `{{number}}` — PR number
- `{{head_sha}}` — full commit SHA
- `{{head_short_sha}}` — **8-char** short SHA (not 7 — important for image tagging!)
- `{{branch}}` — source branch name

**Inline kustomize overrides** — PR-specific values (image tag, APP_URL, client ID, Ingress host, client secret) are injected directly in the ApplicationSet `source.kustomize` block. No per-PR git files are committed.

### Kustomize Base/Overlay Pattern

```
gitops/environments/
├── base/           # Generic manifests (no namespace, placeholder config values)
└── overlays/
    ├── dev/        # JSON patches for dev-specific values; image tags updated by CI
    ├── prod/       # JSON patches for prod; always uses same tag validated in dev
    └── preview/    # Minimal overlay; all PR-specific values injected by ApplicationSet
```

Per-overlay patches applied via JSON Patch (RFC 6902):
- `config-patch.yaml` — APP_URL, FRONTEND_URL, KEYCLOAK_CLIENT_ID
- `ingress-patch.yaml` — Ingress hostname
- `secret-patch.yaml` — KEYCLOAK_CLIENT_SECRET (per-env client secret)

### Registry Mirror (Post-Creation)

`containerdConfigPatches` in `kind-config.yaml` crashes the kubelet on macOS + Docker Desktop + kindest/node:v1.35. Registry mirror is configured post-cluster-creation by writing into the Kind node:

```bash
docker exec kind-node bash -c "
  mkdir -p /etc/containerd/certs.d/localhost:5001
  cat > /etc/containerd/certs.d/localhost:5001/hosts.toml << TOML
server = \"http://registry:5000\"
[host.\"http://registry:5000\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
TOML
"
```

### CoreDNS Override (Replaces hostAliases)

All pods in all namespaces resolve `idp.keycloak.com` via a CoreDNS `hosts` block pointing to the Kind node IP. Eliminates the need for `hostAliases` in every deployment manifest:

```
hosts {
  172.19.0.3 idp.keycloak.com
  fallthrough
}
```

### Three-Tier Deployment Flow

```
PR opened  → Jenkins builds pr-{N}-{8-char-sha} images
           → Labels PR 'preview'
           → ArgoCD creates student-app-pr-{N} (ephemeral)
           → E2E tests pass
           → PR merged → namespace auto-deleted

dev branch → Jenkins builds dev-{sha} images
           → Updates dev overlay kustomization.yaml
           → ArgoCD syncs student-app-dev
           → E2E tests pass
           → Jenkins opens dev→prod PR

main branch → Jenkins reads dev image tag (no rebuild)
            → Updates prod overlay kustomization.yaml
            → ArgoCD syncs student-app-prod
            → E2E tests pass
```

---

## Architecture Patterns

### BFF (Backend-for-Frontend)

Nginx serves the React SPA and proxies `/api/` requests to FastAPI. All auth tokens stay server-side in Redis sessions. Session cookies flow through Nginx on the same origin, eliminating CORS.

```
Browser → Nginx (SPA + /api proxy) → FastAPI → Redis/PostgreSQL
                                    → Keycloak (OAuth2.1 PKCE)
```

### OAuth2.1 + PKCE (S256)

- Authorization Code flow with Proof Key for Code Exchange
- Authlib handles PKCE challenge/verifier generation
- Tokens stored in Redis-backed sessions, never exposed to browser
- Custom SSL context for self-signed Keycloak TLS certificates

### Declarative RBAC (FastAPI Dependencies)

```python
# Route-level access control via dependency injection
@router.get("/", dependencies=[Depends(require_authenticated)])
@router.post("/", dependencies=[Depends(require_admin)])
```

- `require_authenticated` — extracts user from session or 401
- `require_admin` — checks admin role or 403
- `get_student_for_user` — resource-level ownership check (student sees own record only)

### Redis-Backed Sessions (ASGI Middleware)

Custom `RedisSessionMiddleware`:
- `redis.asyncio` for non-blocking session read/write
- `itsdangerous.Signer` for tamper-proof session cookies
- 14-day TTL with automatic expiry
- Enables multi-replica session consistency

### CSS Custom Properties (Theming)

```css
:root { --bg-color: #f5f5f5; --card-bg: #ffffff; }
[data-theme="dark"] { --bg-color: #121212; --card-bg: #1e1e1e; }
```

- ThemeContext reads/writes `localStorage('theme')`
- Sets `data-theme` attribute on `<html>`
- Zero JavaScript style calculations — pure CSS

---

## Kubernetes Patterns

### StatefulSet (Keycloak)

- 3 replicas with ordered startup (keycloak-0, keycloak-1, keycloak-2)
- Headless service for peer discovery (jdbc-ping)
- Management port 9000 for health probes (separate from HTTPS 8443)

### Deployment (FastAPI, Frontend, Redis, PostgreSQL)

- 3 replicas for FastAPI and Frontend
- Single replica for Redis and PostgreSQL (stateful data)
- `hostAliases` with `__NODE_IP__` placeholder substituted at deploy time

### Service Types

| Service | Type | Port |
|---------|------|------|
| Frontend (Nginx) | NodePort | 30000 |
| Keycloak | NodePort | 31111 |
| FastAPI | ClusterIP | 8000 |
| Redis | ClusterIP | 6379 |
| PostgreSQL (app) | ClusterIP | 5432 |
| PostgreSQL (keycloak) | ClusterIP | 5432 |

### Secret Management

- `keycloak-tls` — TLS cert + key + CA cert
- `keycloak-secret` — admin credentials
- `postgresql-secret` — DB credentials
- `app-postgresql-secret` — app DB credentials
- `fastapi-app-secret` — app secret key + Keycloak client secret

---

## Testing Skills

### Playwright E2E Patterns

**Login helper** — navigates to `/api/auth/login`, fills Keycloak form, waits for redirect + navbar badge:
```typescript
export async function login(page: Page, role: 'admin' | 'student' | 'staff') {
  await page.goto('/api/auth/login');
  await page.waitForSelector('#username', { timeout: 15000 });
  await page.fill('#username', username);
  await page.fill('#password', password);
  await page.click('#kc-login');
  await page.waitForURL('**/', { timeout: 15000 });
  await page.waitForSelector('.navbar .badge, .login-container', { timeout: 10000 });
}
```

**Test categories:**
- Authentication (login/logout, session persistence)
- CRUD operations (create, read, update via forms)
- Role-based access (admin/staff/student visibility, form access control)
- Navigation (navbar links, dashboard cards, list-to-detail)
- Form validation (HTML5 required field enforcement)
- Error handling (404, 403, cross-user access)
- Dark mode (toggle, localStorage, CSS application)

**Strict mode awareness:** Always scope selectors to avoid matching duplicate elements (e.g., `.navbar .badge` instead of `.badge`).

### Test Data Seeding

- Keycloak Admin REST API to resolve user IDs
- `kubectl exec` into FastAPI pod for database seeding
- Idempotent (checks existence before creating)

---

## Script Automation Skills

### All-in-One Pipeline (`scripts/clean-deploy-test.sh`)

8-phase lifecycle: Clean → Certs → Kind Cluster → Infrastructure → Build & Deploy → Seed DB → Verify → E2E Tests

Key techniques:
- `wait_for_pods()` — polls for pod scheduling before `kubectl wait`
- `wait_for_url()` — HTTP polling with timeout
- `get_admin_token()` — Keycloak admin token via client credentials
- Port-forward fallback if NodePort unreachable
- Automatic venv recreation to avoid stale interpreter paths
- `sed` substitution for `__NODE_IP__` in deployment manifests
- Multi-stage Docker builds (node → nginx, python slim)

### Docker Multi-Stage Builds

**Backend:**
```dockerfile
FROM python:3.12-slim
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
COPY certs/ca.crt /usr/local/share/ca-certificates/keycloak-ca.crt
```

**Frontend:**
```dockerfile
FROM node:22-alpine AS build
RUN npm ci && npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
```

---

## API Design

### Backend Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/health` | none | Health check |
| GET | `/api/auth/login` | none | Redirect to Keycloak |
| GET | `/api/auth/callback` | none | OAuth callback |
| GET | `/api/auth/me` | session | Current user + roles |
| POST | `/api/auth/logout` | session | Clear session, return logout URL |
| GET | `/api/students/` | authenticated | List students (role-filtered) |
| POST | `/api/students/` | admin | Create student |
| GET | `/api/students/{id}` | authenticated | Student detail (ownership check) |
| PUT | `/api/students/{id}` | admin | Update student |
| GET | `/api/departments/` | authenticated | List departments |
| POST | `/api/departments/` | admin | Create department |
| GET | `/api/departments/{id}` | authenticated | Department detail + students |
| PUT | `/api/departments/{id}` | admin | Update department |

### Frontend API Client

```typescript
async function apiFetch<T>(url: string, options?: RequestInit): Promise<T> {
  const res = await fetch(url, { credentials: 'include', ...options });
  if (!res.ok) throw new ApiError(res.status, await res.text());
  return res.json();
}
```

- `credentials: 'include'` ensures session cookies are sent
- `ApiError` class carries status code for role-based error handling in UI
