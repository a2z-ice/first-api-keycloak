# Plan 8: Professional Logout Button + Complete Presentation.md

## Problem Statement

Two distinct issues need resolution:

1. **Logout button is visually inactive / invisible** — The button uses the class combination `btn btn-sm btn-outline`. The `.btn-outline` style applies `color: var(--text)` (resolves to `#333` — dark grey) and `border-color: var(--text-muted)` (`#999`) against the dark navy navbar background (`#1a1a2e`). The result is near-invisible dark text on a dark background: the button reads as inactive or disabled.

2. **Broken image references in presentation.md** — Section 13 (lines 1012–1256) references 12 screenshot files that do not exist on disk (`65-p1-dev-dashboard.png` through `81-final-kubectl-rollouts.png`). These were never captured. Every other section (1–12) uses screenshots `01.png` through `54.png` which **all exist**. Section 13 is a functional duplicate of Section 12 with different (non-existent) filenames.

---

## Part 1: Logout Button Fix

### Root Cause

The `.btn-outline` class is designed for use on light page backgrounds — not inside the dark navbar. Its color variables resolve to values appropriate for light content areas, making the button text blend into the dark navbar:

```css
/* Current — broken in navbar context */
.btn-outline {
  background: transparent;
  border-color: var(--text-muted);  /* resolves to #999 */
  color: var(--text);               /* resolves to #333 — near invisible on dark bg */
}
```

### Fix: Add `.btn-logout` class

Add a dedicated logout button style that is hardcoded for the dark navbar context — not tied to theme CSS variables. Use a subtle red tint to signal the destructive/exit action without being aggressive.

**File: `frontend/src/App.css`** — add after the `.theme-toggle:hover` block:

```css
/* Logout button — styled for dark navbar context */
.btn-logout {
  background: rgba(239, 68, 68, 0.12);
  border: 1px solid rgba(239, 68, 68, 0.4);
  color: #fca5a5;
  font-size: 0.8rem;
  padding: 0.3rem 0.85rem;
  border-radius: 4px;
  cursor: pointer;
  font-weight: 500;
  letter-spacing: 0.01em;
  transition: background 0.15s ease, border-color 0.15s ease;
}

.btn-logout:hover {
  background: rgba(239, 68, 68, 0.25);
  border-color: rgba(239, 68, 68, 0.65);
  color: #fca5a5;
}
```

**File: `frontend/src/components/Navbar.tsx`** — change the logout button `className`:

```diff
- <button className="btn btn-sm btn-outline" onClick={handleLogout}>
+ <button className="btn-logout" onClick={handleLogout}>
    Logout
  </button>
```

### Visual Result

| State | Appearance |
|-------|-----------|
| Default | Subtle red-tinted border (`rgba(239,68,68,0.4)`), light pink text (`#fca5a5`), near-transparent background |
| Hover | Stronger red tint background, brighter border — clear interactive feedback |
| Contrast | Always visible against dark navbar — hardcoded colours, not theme-variable dependent |

---

## Part 2: presentation.md — Complete Rewrite

### Root Cause of Missing Images

Section 13 was added as a second pass at the same content covered in Section 12, but with new screenshot numbers (65–81) that were never captured. Section 12 covers the identical three-phase pipeline run using screenshots 30–54, all of which exist on disk.

### Fix

**Remove Section 13 entirely.** Section 12 is comprehensive, accurate, and fully illustrated. The complete presentation using only existing screenshots (01–54) is produced.

Additionally, the existing presentation has several structural and tone issues:
- Heading numbers are inconsistent (Section 2 is used for both Jenkins and ArgoCD; Sections 3–6 in table of contents don't match body headings numbered 2–5)
- Bullet lists use "What this shows:" repeatedly — passive and informal
- ArgoCD version in the tech stack table shows v3.0.5 (the project was upgraded to v3.3.1)
- Section 13's bug report includes raw code blocks better suited for a technical deep-dive doc, not a deployment presentation

### New Document Structure

```
1. Executive Summary
2. System Architecture
3. CI/CD Pipeline: Jenkins Automation
   3.1 Dashboard
   3.2 Dev Pipeline Job
   3.3 PR Preview Pipeline Job
   3.4 Production Pipeline Job
   3.5 Jenkins Credentials
   3.6 Dev Pipeline Stages
   3.7 PR Preview Pipeline Stages
   3.8 Production Pipeline Stages
4. GitOps: ArgoCD Application Status
   4.1 Application Overview
   4.2 Development Environment
   4.3 Full Resource Tree
   4.4 Production Environment
   4.5 Resource Inspector
5. Argo Rollouts: Canary Deployment
   5.1 Canary Strategy Configuration
   5.2 Dev Rollouts
   5.3 Production Rollouts
   5.4 Rollouts Controller
   5.5 Application Status
   5.6 Custom Resource Definitions
6. Application: Development Environment
   6.1 Keycloak Login
   6.2 Admin Dashboard
   6.3 Student Management
   6.4 Department Management
   6.5 Dark Mode
   6.6 Student Role (Limited View)
7. Application: Production Environment
   7.1 Production Dashboard
   7.2 Production Student List
8. End-to-End Test Results
9. Deployment Pipeline Flow
10. Key Benefits
11. Infrastructure Summary
12. Feature Delivery: Backchannel Logout Fix (End-to-End)
    12.0 Code Change
    12.1 Phase 1 — Dev Pipeline
    12.2 Phase 2 — PR Preview
    12.3 Phase 3 — Production Promotion
    12.4 Final State
    12.5 Pipeline Summary
    12.6 Key Metrics
```

### Professional Tone Guidelines Applied

- Replace "What this shows:" with direct declarative statements about what the screenshot demonstrates
- Use active voice throughout ("ArgoCD detects the change" not "what this shows is that ArgoCD detects")
- Consistent use of bold for technical terms on first use
- Add transition sentences between sections to create narrative flow
- Fix all section numbering inconsistencies

---

## Files Changed

| File | Type of Change |
|------|---------------|
| `frontend/src/App.css` | Add `.btn-logout` CSS class after `.theme-toggle:hover` |
| `frontend/src/components/Navbar.tsx` | Change logout button `className` |
| `presentation.md` | Full rewrite: remove Section 13, fix numbering, professional tone |

---

## Build & Deploy Steps (after code fix)

The logout button CSS change requires rebuilding and redeploying the frontend image. Run after Docker Desktop is started:

```bash
# Option A: Full clean rebuild
./scripts/clean-and-redeploy.sh

# Option B: Rebuild images + redeploy to existing cluster
./scripts/build-test-deploy.sh --deploy-only

# Capture updated screenshots (shows improved logout button)
bash scripts/refresh-screenshots.sh --no-push
```

---

## Verification

1. Deploy the updated frontend — open `http://dev.student.local:8080`
2. The Logout button in the navbar should show a visible red-tinted border with pink text
3. Hovering should produce a visible darker red highlight
4. Click Logout — browser should navigate to `/login` within the app domain (no `idp.keycloak.com` redirect)
5. Open `presentation.md` in any Markdown viewer — all 54 screenshot references (01–54) should resolve and display
6. No broken image links anywhere in the document
7. Section 12 provides a complete three-phase pipeline walkthrough with all screenshots present
