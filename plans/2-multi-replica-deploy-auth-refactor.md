# Plan 2: Multi-Replica Deployment with Auth Refactoring

> **Plan Name**: multi-replica-deploy-auth-refactor
> **Created**: 2026-02-16
> **Status**: Implemented

---

## Summary

Enhancement to the Student Management System that:
- Refactors authorization from inline checks to declarative FastAPI dependencies
- Migrates from SQLite to PostgreSQL for production persistence
- Replaces Starlette's in-memory SessionMiddleware with Redis-backed sessions
- Dockerizes the FastAPI app and deploys 3 replicas to the existing Kind cluster
- Creates an automated build-deploy-test pipeline

## Key Configuration

| Item | Value |
|------|-------|
| FastAPI Replicas | 3 |
| FastAPI NodePort | 32000 (deployed) / 8000 (local) |
| App PostgreSQL | `appuser`/`apppass` @ `app-postgresql:5432/studentdb` |
| Redis | `redis:6379/0` (session store) |
| Session TTL | 14 days |
| Docker Image | `fastapi-student-app:latest` (Kind local) |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Kind Cluster (keycloak-cluster)                              │
│                                                              │
│  ┌─────────────────┐   ┌─────────────────────────────────┐  │
│  │  Keycloak (x3)  │   │  FastAPI App (x3)               │  │
│  │  StatefulSet     │   │  Deployment                     │  │
│  │  :8443 → :31111  │   │  :8000 → :32000                │  │
│  └────────┬────────┘   └──────┬──────────┬───────────────┘  │
│           │                   │          │                   │
│  ┌────────┴────────┐  ┌──────┴───┐  ┌───┴──────────────┐   │
│  │ Keycloak PG     │  │  Redis   │  │ App PostgreSQL   │   │
│  │ (keycloak DB)   │  │  :6379   │  │ (studentdb)      │   │
│  └─────────────────┘  └──────────┘  └──────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

## Authorization Pattern

**Before** (inline checks, repeated 8+ times):
```python
@router.get("/new")
async def new_student_form(request):
    user = get_current_user(request)
    roles = get_user_roles(request)
    if "admin" not in roles:
        raise HTTPException(status_code=403, detail="Admin access required")
    ...
```

**After** (declarative dependency):
```python
@router.get("/new", dependencies=[Depends(require_admin)])
async def new_student_form(request):
    ...
```

Dependencies defined in `app/dependencies.py`:
- `require_authenticated` — returns user or raises 401
- `require_admin` — checks admin role or raises 403
- `inject_user_context` — returns `(user, roles)` tuple

## Session Management

Redis-backed session middleware (`app/session.py`):
- Cookie signed with `itsdangerous.URLSafeSerializer`
- Session data stored as JSON in Redis with `session:{uuid}` keys
- 14-day TTL, auto-renewed on each request
- Graceful degradation if Redis is unavailable

## Database Migration

- `database.py` conditionally applies `check_same_thread: False` only for SQLite
- Local dev: `DATABASE_URL=sqlite:///./students.db` (default)
- Deployed: `DATABASE_URL=postgresql://appuser:apppass@app-postgresql:5432/studentdb`

## Test Users

| Username | Password | Role |
|----------|----------|------|
| admin-user | admin123 | admin |
| student-user | student123 | student |
| staff-user | staff123 | staff |

## Infrastructure

| Component | Image | Replicas | Port |
|-----------|-------|----------|------|
| FastAPI App | fastapi-student-app:latest | 3 | 32000 (NodePort) |
| App PostgreSQL | postgres:15-alpine | 1 | 5432 (ClusterIP) |
| Redis | redis:7-alpine | 1 | 6379 (ClusterIP) |
| Keycloak | quay.io/keycloak/keycloak:26.5.3 | 3 | 31111 (NodePort) |
| Keycloak PG | postgres:15-alpine | 1 | 5432 (ClusterIP) |

## Pipeline Usage

```bash
# Full pipeline: seed → local test → build → deploy → seed deployed → test deployed
./scripts/deploy-and-test.sh

# Skip local tests (Keycloak cluster must be running)
./scripts/deploy-and-test.sh --skip-local-tests

# Only deploy (skip all tests)
./scripts/deploy-and-test.sh --only-deploy

# Only test the deployed app (assumes already deployed)
./scripts/deploy-and-test.sh --only-test-deployed

# Skip Docker build (use existing image)
./scripts/deploy-and-test.sh --skip-build
```

## E2E Test Suites

| Suite | Tests | Description |
|-------|-------|-------------|
| TestAuthentication | 5 | Login, redirect, logout flows |
| TestStudentAccess | 9 | Role-based student page access |
| TestDepartmentAccess | 6 | Role-based department page access |
| TestDepartmentCRUD | 5 | Admin CRUD for departments |
| TestStudentCRUD | 5 | Admin CRUD for students |
| TestNavigation | 4 | Navbar, dashboard, list-to-detail |
| TestFormValidation | 3 | Required field validation |
| TestErrorHandling | 3 | 404s, cross-student access |
| TestSessionConsistency | 2 | Session persistence across requests |

Tests are configurable via `APP_URL` environment variable:
- `APP_URL=http://localhost:8000` — test local app (default)
- `APP_URL=http://localhost:32000` — test deployed app
