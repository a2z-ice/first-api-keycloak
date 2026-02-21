# Plan: Logout Fix — Backchannel Keycloak Logout + App Redirect

## Context

Currently, clicking "Logout" in the Student Management app redirects the browser through Keycloak's logout page before returning to `/login`. The user sees Keycloak's UI briefly, which is poor UX. The goal is to:
1. Keep the user **entirely within the app** — clicking Logout immediately shows the app's own `/login` page
2. Silently terminate the Keycloak session **server-side** (backchannel logout) so Keycloak is fully logged out without any browser redirect to Keycloak

**Trigger:** `refresh_token` is required for Keycloak backchannel logout but was previously discarded in the OAuth callback. `httpx` is already in `requirements.txt` — no new dependencies needed.

---

## File Inventory

| File | Action | Change Summary |
|------|--------|----------------|
| `backend/app/routes/auth_routes.py` | Modified | Store `refresh_token` in session during callback; backchannel logout in logout endpoint |
| `frontend/src/api/auth.ts` | Modified | Changed return type from `{ logout_url: string }` to `{ redirect: string }` |
| `frontend/src/components/Navbar.tsx` | Modified | Changed `window.location.href = logout_url` to `navigate(data.redirect)` |
| `frontend/tests/e2e/auth.spec.ts` | Modified | Updated comment on logout test (behavior same, comment was wrong) |
| `plans/7-logout-fix-backchannel.md` | Created | This plan file |

---

## Changes Made

### Step 1 — Backend: Store `refresh_token` in Session (callback)

In `auth_routes.py` `auth_callback()`, added `refresh_token` to the session token dict:

```python
request.session["token"] = {
    "access_token": access_token,
    "refresh_token": token.get("refresh_token", ""),
    "resource_access": access_claims.get("resource_access", {}),
}
```

### Step 2 — Backend: Backchannel Logout Endpoint

Replaced the redirect-based logout with a backchannel POST to Keycloak's token endpoint:

```python
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
    return {"redirect": "/login"}
```

- `verify=False` because Keycloak uses a self-signed cert; this is an internal pod-to-Keycloak call
- `try/except` with `pass`: a failed Keycloak call must not prevent local session clear
- Added `import httpx` at the top of the file

### Step 3 — Frontend: API Return Type

Changed `logout()` return type from `{ logout_url: string }` to `{ redirect: string }`.

### Step 4 — Frontend: Navbar Logout Handler

Changed `window.location.href = logout_url` to `navigate(redirect)` — SPA navigation, no page reload, no Keycloak redirect visible to user.

### Step 5 — E2E Test: Updated Comment

Updated the comment from "Keycloak redirects back to login page" to "backend clears session and app navigates to /login directly". Test assertions unchanged.

---

## Before / After

| Aspect | Before | After |
|--------|--------|-------|
| Logout flow | App → Keycloak logout page → App `/login` | App calls backend → backend calls Keycloak silently → App navigates to `/login` |
| User sees | Brief Keycloak UI flash | Stays entirely in the app |
| Keycloak session | Terminated via browser redirect | Terminated via server-side backchannel POST |
| Response field | `logout_url` | `redirect` |

---

## Verification

1. Log in as any user → click Logout → URL stays at `/login` (no `idp.keycloak.com` visible)
2. Check Keycloak Admin console → Sessions → verify no active session for the user
3. E2E: `cd frontend && APP_URL=http://dev.student.local:8080 npx playwright test tests/e2e/auth.spec.ts`

---

## Deployment Results (2026-02-20)

**Additional fix applied during deployment:** Commit `5bc3bf4` changed `return {"redirect": "/login"}` → `return {"redirect": "/"}` so the frontend navigates to root and React Router `ProtectedRoute` handles the `/login` redirect. This matches the user's expected flow ("redirected to home page which then redirects to login page").

**Image tag:** `dev-5bc3bf4`

**Socat proxy issue discovered:** The existing `argocd-http-proxy` + `argocd-https-proxy` Docker containers had been started with node IP `172.19.0.2` but the current cluster node IP was `172.19.0.3`. This caused the `setup_argocd_login()` check in `cicd-pipeline-test.sh` to time out. Fix: recreate proxy containers with correct node IP before running the pipeline. See CLAUDE.md "Current State" section for the recreate command.

**Pipeline phases run via `cicd-pipeline-test.sh --skip-setup`:**

| Phase | Environment | Image Tag | E2E | Time |
|-------|-------------|-----------|-----|------|
| 1 (dev) | `student-app-dev` | `dev-5bc3bf4` | 45/45 ✅ | 15.9s |
| 2 (PR preview) | `student-app-pr-7` | `pr-7-72794915` | 45/45 ✅ | 17.1s |
| 3 (prod) | `student-app-prod` | `dev-5bc3bf4` | 45/45 ✅ | 16.7s |

**Git branches after deployment:**
- `argo-rollout` @ `72f6cd8` (fix commit + presentation Section 13)
- `dev` @ `01fb198` (dev overlay: `dev-5bc3bf4`)
- `main` @ `14c4063` (prod overlay: `dev-5bc3bf4`)

**Presentation:** Section 13 added to `presentation.md` — 244 lines documenting the bug report, root cause, fix, all three pipeline phases, and summary table.

**Phase 2 note:** The pipeline prompts for a `/etc/hosts` entry via `/dev/tty`. When running non-interactively (e.g., from Claude Code), add the entry manually _before_ running:
```bash
echo '127.0.0.1 pr-N.student.local' | sudo tee -a /etc/hosts
```
Then use `--pr-number N` to reuse the already-created PR and skip recreation. After Phase 2 completes, remove with:
```bash
sudo sed -i '' '/pr-N.student.local/d' /etc/hosts
```
