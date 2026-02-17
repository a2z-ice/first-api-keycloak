# Plan 3: React Frontend + FastAPI JSON API (BFF Migration)

> **Plan Name**: react-frontend-bff-migration
> **Created**: 2026-02-16
> **Status**: Implemented

---

## Summary

Migration of the Student Management System from FastAPI + Jinja2 server-side rendering to:
- **React 19 SPA frontend** (TypeScript, Vite, React Router 7) served by Nginx
- **FastAPI JSON API backend** (Pydantic schemas, no templates)
- **BFF (Backend-for-Frontend) pattern** — Nginx proxies `/api/` to FastAPI, same-origin cookies
- **Dark mode** with CSS custom properties and localStorage persistence
- **45 Playwright E2E tests** with HTML report generation
- **Single clean-deploy-test script** for full lifecycle automation

## Key Configuration

| Item | Value |
|------|-------|
| Frontend URL (deployed) | http://localhost:30000 |
| Frontend URL (dev) | http://localhost:5173 |
| Backend API (internal) | ClusterIP fastapi-app:8000 |
| Frontend Image | `frontend-student-app:latest` |
| Backend Image | `fastapi-student-app:latest` |
| Frontend Replicas | 3 |
| Backend Replicas | 3 |
| Nginx Proxy | `/api/` → `http://fastapi-app:8000` |
| SPA Fallback | `try_files $uri $uri/ /index.html` |
| Test Framework | Playwright (chromium, workers=1) |
| Test Count | 45 E2E tests |

## Architecture

```
Browser (localhost:30000)
    |
    v
Nginx (React SPA + API Proxy)   <-- NodePort 30000
    |         |
    |         v
    |    FastAPI API             <-- ClusterIP 8000
    |         |       |
    |         v       v
    |      Redis    App PostgreSQL
    |
    v
Keycloak (NodePort 31111)
```

### Why BFF Pattern

- OAuth tokens never reach the browser — stored server-side in Redis sessions
- Session cookies flow naturally through Nginx (same origin) — no CORS needed
- Existing Authlib + Redis session infrastructure preserved unchanged
- Single domain for frontend + API eliminates cross-origin complexities

### Auth Flow

1. React navigates to `/api/auth/login` → Nginx proxies to FastAPI → redirects to Keycloak
2. Keycloak authenticates → redirects to `/api/auth/callback` → Nginx proxies to FastAPI
3. FastAPI stores tokens in Redis session, sets session cookie, redirects to frontend root
4. React calls `GET /api/auth/me` → gets user + roles from session
5. Logout: React calls `POST /api/auth/logout` → gets Keycloak logout URL → navigates there

## Phases

### Phase 1: Rename `fastapi-app/` → `backend/`

- `git mv fastapi-app backend`
- Updated all script references: `build-test-deploy.sh`, `deploy-and-test.sh`, `run-tests.sh`, `create-test-data.py`, `setup.sh`, `cleanup.sh`, `CLAUDE.md`

### Phase 2: Convert Backend to JSON API

- Created `backend/app/schemas.py` — Pydantic models (StudentCreate/Update/Response, DepartmentCreate/Update/Response/DetailResponse, UserResponse)
- Rewrote `auth_routes.py` — prefix `/api/auth`, added `GET /me` (user+roles JSON), changed logout to `POST` returning `{logout_url}`
- Rewrote `student_routes.py` — prefix `/api/students`, JSON responses, PUT for update, role-filtered list
- Rewrote `department_routes.py` — prefix `/api/departments`, JSON responses, detail includes nested students
- Rewrote `main.py` — removed SSR (StaticFiles, Jinja2Templates), added `GET /api/health`
- Updated `config.py` — added `frontend_url` setting
- Deleted `backend/templates/` and `backend/static/`
- Removed `jinja2` and `python-multipart` from `requirements.txt`
- Updated Dockerfile — removed template/static COPY lines
- Updated K8s health probes from `/login-page` to `/api/health`
- Changed `app-service.yaml` from NodePort to ClusterIP
- Updated `app-config.yaml` — `APP_URL` and `FRONTEND_URL` set to `http://localhost:30000`

### Phase 3: React Frontend

**Tech stack:** React 19, TypeScript 5.7, Vite 6, React Router 7

**Directory structure:**
```
frontend/src/
  api/          — client.ts (fetch wrapper), auth.ts, students.ts, departments.ts
  types/        — User, Student, Department, DepartmentDetail interfaces
  contexts/     — AuthContext (calls /api/auth/me on mount), ThemeContext (dark mode)
  components/   — Navbar, ProtectedRoute, AdminRoute
  pages/        — LoginPage, DashboardPage, students/*, departments/*
```

**Routes:**
| Path | Component | Auth |
|------|-----------|------|
| `/login` | LoginPage | none |
| `/` | DashboardPage | authenticated |
| `/students` | StudentListPage | authenticated |
| `/students/new` | StudentFormPage | admin |
| `/students/:id` | StudentDetailPage | authenticated |
| `/students/:id/edit` | StudentFormPage | admin |
| `/departments` | DepartmentListPage | authenticated |
| `/departments/new` | DepartmentFormPage | admin |
| `/departments/:id` | DepartmentDetailPage | authenticated |
| `/departments/:id/edit` | DepartmentFormPage | admin |

### Phase 4: Dark Mode

- `ThemeContext` reads/writes `localStorage('theme')`, defaults to `'light'`
- Sets `data-theme` attribute on `<html>`
- CSS custom properties: light (white cards, #f5f5f5 bg) / dark (#121212 bg, #1e1e1e cards)
- Toggle button in Navbar (moon/sun icons)

### Phase 5: Nginx + Frontend Dockerfile

- `nginx.conf` — proxy `/api/` to backend, SPA fallback, security headers, asset caching
- Multi-stage Dockerfile: `node:22-alpine` build → `nginx:1.27-alpine` runtime

### Phase 6: Kubernetes Manifests

- Updated `cluster/kind-config.yaml` — added NodePort 30000
- Created `keycloak/frontend/frontend-deployment.yaml` — 3 replicas, probes, resource limits
- Created `keycloak/frontend/frontend-service.yaml` — NodePort 30000

### Phase 7: Keycloak + Script Updates

- Updated `realm-setup.sh` — redirect URIs for ports 30000, 5173, 8000
- Rewrote `build-test-deploy.sh` — dual-image build, frontend deployment, Playwright tests
- Updated all helper scripts for new paths

### Phase 8: Playwright E2E Tests

| File | Tests | Coverage |
|------|-------|----------|
| `auth.spec.ts` | 7 | Login (3 roles), logout, session persistence (2), redirect |
| `students.spec.ts` | 14 | Role access (9) + CRUD (5) |
| `departments.spec.ts` | 12 | Role access (6) + CRUD (5) + access control (1) |
| `navigation.spec.ts` | 4 | Navbar links, dashboard cards, list-to-detail |
| `validation.spec.ts` | 3 | Required field validation on forms |
| `errors.spec.ts` | 3 | 404 handling, cross-student access |
| `dark-mode.spec.ts` | 3 | Toggle, localStorage persistence, CSS applied |
| **Total** | **45** | |

### Phase 9: Single Clean-Deploy-Test Script

Created `scripts/clean-deploy-test.sh` — 8-phase all-in-one script:
1. Cleanup (delete cluster, certs, artifacts)
2. Generate TLS certificates
3. Create Kind cluster
4. Deploy infrastructure (namespace, TLS, Keycloak PostgreSQL, Keycloak StatefulSet, realm setup)
5. Build & deploy app (Python venv, Docker images, Kind load, Redis, App PG, FastAPI, Frontend, Keycloak URIs)
6. Seed database (departments, students linked to Keycloak user IDs)
7. Verify deployment (pod status, frontend + API health checks)
8. Run Playwright E2E tests with HTML report

## Files Modified

| File | Change |
|------|--------|
| `backend/app/routes/auth_routes.py` | BFF auth endpoints (JSON API) |
| `backend/app/routes/student_routes.py` | JSON API with role filtering |
| `backend/app/routes/department_routes.py` | JSON API with nested students |
| `backend/app/main.py` | Removed SSR, added /api/health |
| `backend/app/config.py` | Added frontend_url |
| `backend/app/schemas.py` | **NEW** — Pydantic request/response models |
| `backend/Dockerfile` | Removed templates/static |
| `backend/requirements.txt` | Removed jinja2, python-multipart |
| `keycloak/fastapi-app/app-deployment.yaml` | Health probe → /api/health |
| `keycloak/fastapi-app/app-config.yaml` | APP_URL + FRONTEND_URL |
| `keycloak/fastapi-app/app-service.yaml` | NodePort → ClusterIP |
| `cluster/kind-config.yaml` | Added port 30000 |
| `keycloak/realm-config/realm-setup.sh` | Updated redirect URIs |
| `scripts/build-test-deploy.sh` | Dual-image build + frontend deploy |
| `scripts/deploy-and-test.sh` | Updated for new architecture |
| `scripts/run-tests.sh` | Playwright frontend tests |
| `scripts/clean-deploy-test.sh` | **NEW** — all-in-one lifecycle script |
| `setup.sh` | Updated paths + frontend npm ci |
| `cleanup.sh` | Updated paths + frontend cleanup |
| `CLAUDE.md` | Complete rewrite for new architecture |

## Files Created

| File | Purpose |
|------|---------|
| `frontend/package.json` | React 19 + Vite + TypeScript + Playwright |
| `frontend/vite.config.ts` | Dev proxy /api → localhost:8000 |
| `frontend/tsconfig.json` | TypeScript config |
| `frontend/index.html` | SPA entry point |
| `frontend/nginx.conf` | API proxy + SPA fallback + security headers |
| `frontend/Dockerfile` | Multi-stage node build → nginx |
| `frontend/playwright.config.ts` | E2E test config |
| `frontend/src/main.tsx` | React entry point |
| `frontend/src/App.tsx` | Router + providers |
| `frontend/src/App.css` | Full CSS with light/dark theme |
| `frontend/src/types/index.ts` | TypeScript interfaces |
| `frontend/src/api/client.ts` | Fetch wrapper (credentials: include) |
| `frontend/src/api/auth.ts` | getMe(), logout() |
| `frontend/src/api/students.ts` | Student CRUD API |
| `frontend/src/api/departments.ts` | Department CRUD API |
| `frontend/src/contexts/AuthContext.tsx` | Auth state provider |
| `frontend/src/contexts/ThemeContext.tsx` | Dark mode provider |
| `frontend/src/components/Navbar.tsx` | Navigation + user info + theme toggle |
| `frontend/src/components/ProtectedRoute.tsx` | Auth guard |
| `frontend/src/components/AdminRoute.tsx` | Admin role guard |
| `frontend/src/pages/LoginPage.tsx` | Keycloak login redirect |
| `frontend/src/pages/DashboardPage.tsx` | Welcome + card grid |
| `frontend/src/pages/students/*.tsx` | List, Detail, Form pages |
| `frontend/src/pages/departments/*.tsx` | List, Detail, Form pages |
| `frontend/tests/e2e/helpers.ts` | Login helper + test users |
| `frontend/tests/e2e/*.spec.ts` | 7 test suites (45 tests) |
| `keycloak/frontend/frontend-deployment.yaml` | 3-replica Nginx deployment |
| `keycloak/frontend/frontend-service.yaml` | NodePort 30000 |

## Files Deleted

- `backend/templates/` — All Jinja2 templates (base.html, login, home, student/*, department/*)
- `backend/static/` — CSS and JS static files

## Lessons Learned

1. **Strict mode violations**: Playwright's strict mode fails when `.badge` selector matches elements in both navbar and dashboard. Fix: scope to `.navbar .badge`.
2. **Stale venv after git mv**: `git mv fastapi-app backend` moves the venv but its shebang lines still reference the old path. Fix: always recreate venv fresh (`rm -rf venv && python3 -m venv venv`).
3. **Pod scheduling delay**: `kubectl wait --for=condition=ready` fails with "no matching resources" if the pod hasn't been scheduled yet. Fix: poll for pod existence before waiting for readiness.
