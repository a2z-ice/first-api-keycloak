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
| ArgoCD | 3.3.1 | GitOps controller — syncs K8s state from git |
| Argo Rollouts | 1.8.4 | Progressive delivery — canary deployments via Rollout CRDs |
| ArgoCD ApplicationSet | — | Multi-app templating (List + PullRequest generators) |
| Kustomize | built-in | Overlay-based K8s manifest composition |
| Nginx Ingress Controller | — | Routes `*.student.local:8080` to correct namespaces |
| Docker Registry | registry:2 | Local image registry on port 5001 |
| Jenkins | LTS | CI pipeline (Multibranch, declarative Jenkinsfiles) |
| GitHub REST API | v3 | PR label management, SHA resolution |
| gh CLI | — | PR/issue management |

**Pipeline test script**: `scripts/cicd-pipeline-test.sh` — fully automated end-to-end test of all three pipeline phases. Verified working: 54/54 E2E tests pass in dev, PR preview, and prod. Key patterns inside:
- GITHUB_TOKEN retrieved from k8s secret (`argocd/github-token`) if not in environment
- ArgoCD login via `setup_argocd_login()` — connects directly to NodePort `localhost:30080`, no port-forward; prints Docker proxy commands if port is unreachable
- ArgoCD app detection via `kubectl get application` (not `argocd app list`, which is unreliable in non-TTY)
- Seed script restores mutated student names before each E2E run
- No sudo calls — `/etc/hosts` management is printed as instructions for the user
- `check_and_fix_coredns()` uses `kubectl patch rollout ... spec.restartAt` for Argo Rollouts resources (no plugin needed); falls back to `kubectl rollout restart deployment` for backward compat

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

### ArgoCD NodePort Access (No Port-Forward)

`cluster/kind-config.yaml` maps `containerPort 30080 → hostPort 30080` and `30081 → 30081` so ArgoCD's NodePorts are reachable directly from the host. For clusters created **before this mapping was added**, a lightweight `alpine/socat` Docker proxy bridges the gap without cluster recreation:

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
docker run -d --name argocd-http-proxy --network kind --restart unless-stopped \
  -p 30080:30080 alpine/socat TCP-LISTEN:30080,fork,reuseaddr TCP:${NODE_IP}:30080
docker run -d --name argocd-https-proxy --network kind --restart unless-stopped \
  -p 30081:30081 alpine/socat TCP-LISTEN:30081,fork,reuseaddr TCP:${NODE_IP}:30081
```

The proxy containers use `--restart unless-stopped` so they survive Docker Desktop restarts. Verify with `docker ps --filter name=argocd`.

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

### Argo Rollouts — Canary Strategy (Replica-Based)

`fastapi-app` and `frontend-app` are `argoproj.io/v1alpha1 Rollout` resources. No service mesh needed — Argo Rollouts uses replica counts to split traffic proportionally.

```yaml
strategy:
  canary:
    maxSurge: 1
    maxUnavailable: 0
    steps:
      - setWeight: 50     # 1 of 2 pods is canary (50% traffic)
      - pause: {duration: 15s}
      - setWeight: 100    # promote all pods
      - pause: {duration: 10s}
```

Key operational commands (no plugin required):
```bash
# Watch canary progression live
kubectl get rollout fastapi-app -n student-app-dev -w

# Restart a Rollout (triggers pod template annotation bump, initiates canary)
kubectl patch rollout fastapi-app -n student-app-dev \
  -p '{"spec":{"restartAt":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}}' --type=merge

# Verify ArgoCD sees Rollout as Healthy
argocd app get student-app-dev

# Check Rollout history (revisions)
kubectl rollout history rollout/fastapi-app -n student-app-dev
```

ArgoCD 3.x has native Rollout health checks — `argocd app wait --health` automatically waits for the canary to complete before returning.

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
            → Argo Rollouts canary completes
            → E2E tests pass
```

**Pre-test cleanup** (required when migrating from Deployment → Rollout on a live cluster):
```bash
kubectl delete deployment fastapi-app frontend-app -n student-app-dev 2>/dev/null || true
kubectl delete deployment fastapi-app frontend-app -n student-app-prod 2>/dev/null || true
kubectl delete replicasets -n student-app-dev -l app=fastapi-app 2>/dev/null || true
kubectl delete replicasets -n student-app-dev -l app=frontend-app 2>/dev/null || true
kubectl delete replicasets -n student-app-prod -l app=fastapi-app 2>/dev/null || true
kubectl delete replicasets -n student-app-prod -l app=frontend-app 2>/dev/null || true
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

### Rollout (FastAPI, Frontend) — Argo Rollouts CRDs

- `fastapi-app` and `frontend-app` use `argoproj.io/v1alpha1 Rollout` (not `apps/v1 Deployment`)
- Canary strategy — replica-based traffic splitting (no service mesh required)
- FastAPI steps: setWeight 50% → pause 15s → setWeight 100% → pause 10s
- Frontend steps: setWeight 50% → pause 10s
- ArgoCD 3.x tracks Rollout health natively; `argocd app wait --health` waits for canary completion
- To watch canary progress: `kubectl get rollout fastapi-app -n student-app-dev -w`
- To restart without plugin: `kubectl patch rollout <name> -n <ns> -p '{"spec":{"restartAt":"<ISO8601>"}}' --type=merge`

### Deployment (Redis, PostgreSQL)

- Single replica for Redis and PostgreSQL (stateful data)

### Service Types

| Service | Type | Port |
|---------|------|------|
| Frontend (Nginx) | NodePort | 30000 |
| Keycloak | NodePort | 31111 |
| ArgoCD (HTTP) | NodePort | 30080 → redirects to HTTPS |
| ArgoCD (HTTPS) | NodePort | 30081 |
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
| POST | `/api/auth/logout` | session | Backchannel logout Keycloak + clear session, return `{"redirect": "/"}` |
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

---

## Auth Patterns

### Backchannel Logout (Server-Side Keycloak Session Termination)

Instead of redirecting the browser through Keycloak's logout page (front-channel), the backend silently POSTs the `refresh_token` to Keycloak's token revocation endpoint. The user stays entirely within the app domain.

```python
# backend/app/routes/auth_routes.py
@router.post("/logout")
async def logout(request: Request):
    token_data = request.session.get("token", {})
    refresh_token = token_data.get("refresh_token", "")

    if refresh_token:
        try:
            async with httpx.AsyncClient(verify=False) as client:
                await client.post(
                    f"{settings.keycloak_url}/realms/{settings.keycloak_realm}"
                    f"/protocol/openid-connect/logout",
                    data={
                        "client_id": settings.keycloak_client_id,
                        "client_secret": settings.keycloak_client_secret,
                        "refresh_token": refresh_token,
                    },
                )
        except Exception:
            pass  # Best-effort — clear session regardless

    request.session.clear()
    return {"redirect": "/"}   # Root; ProtectedRoute detects unauthenticated → /login
```

Key points:
- `verify=False` — Keycloak uses a self-signed cert; this is a pod-internal call
- `try/except pass` — failed Keycloak call must never prevent local session clearing
- Return `{"redirect": "/"}` not `{"redirect": "/login"}` — React Router `ProtectedRoute` handles the final redirect to `/login` after detecting unauthenticated state
- `refresh_token` must be stored in session during OAuth callback (`token.get("refresh_token", "")`)

**Frontend side:**
```typescript
// src/api/auth.ts
export async function logout(): Promise<{ redirect: string }> {
  const res = await apiFetch<{ redirect: string }>('/api/auth/logout', { method: 'POST' });
  return res;
}

// src/components/Navbar.tsx
const { redirect } = await logout();
navigate(redirect);  // SPA navigate — no page reload, no Keycloak URL visible
```

---

## Operational Gotchas

### socat Proxy Stale Node IP

**Symptom:** `cicd-pipeline-test.sh` times out at "Waiting for ArgoCD to be reachable at localhost:30080" even though `docker ps` shows the proxy containers are running.

**Cause:** The `argocd-http-proxy` and `argocd-https-proxy` Docker containers were started with an old Kind node IP. After cluster recreation the node IP changes, but `--restart unless-stopped` keeps the old containers running with the stale destination.

**Diagnosis:**
```bash
docker inspect argocd-http-proxy --format '{{.Args}}'
# Shows: [TCP-LISTEN:30080,fork,reuseaddr TCP:172.19.0.2:30080]
kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
# Shows: 172.19.0.3  ← mismatch!
```

**Fix:** Recreate proxy containers with the correct node IP:
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
docker rm -f argocd-http-proxy argocd-https-proxy
docker run -d --name argocd-http-proxy --network kind --restart unless-stopped \
  -p 30080:30080 alpine/socat TCP-LISTEN:30080,fork,reuseaddr TCP:${NODE_IP}:30080
docker run -d --name argocd-https-proxy --network kind --restart unless-stopped \
  -p 30081:30081 alpine/socat TCP-LISTEN:30081,fork,reuseaddr TCP:${NODE_IP}:30081
```

**Prevention:** After every cluster recreation, rerun `bash scripts/setup-argocd.sh` which recreates the proxies with the fresh node IP.

### ArgoCD CLI gRPC via socat

socat passes TCP (HTTP/1.1) but not gRPC (HTTP/2). The `argocd` CLI uses gRPC, so it cannot connect through the socat NodePort proxy on `localhost:30080`.

- **Browser UI** → use `http://localhost:30080` (socat works fine for HTTP)
- **`argocd` CLI** → always use `kubectl port-forward`:
  ```bash
  kubectl port-forward svc/argocd-server 18080:80 -n argocd &
  argocd login localhost:18080 --insecure --username admin \
    --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  ```

### Phase 2 PR Preview /etc/hosts Prompt

`cicd-pipeline-test.sh` Phase 2 pauses and reads from `/dev/tty` to confirm the user has added a `/etc/hosts` entry for `pr-N.student.local`. This cannot be automated from Claude Code (no `/dev/tty`).

**Workaround:**
1. Add the entry manually before the script reaches that point:
   ```bash
   echo '127.0.0.1 pr-N.student.local' | sudo tee -a /etc/hosts
   ```
2. If the PR was already created, reuse it with `--pr-number N` (script skips creation and checks hosts entry, which now passes immediately).
3. After Phase 2 completes, remove the entry:
   ```bash
   sudo sed -i '' '/pr-N.student.local/d' /etc/hosts
   ```
