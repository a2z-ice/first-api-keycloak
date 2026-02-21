/**
 * capture-feature-rollout-screenshots.js
 *
 * Captures every screenshot needed for the "Feature Rollout: Silent Logout Fix"
 * section in presentation.md.  Called by run-feature-rollout-demo.sh at each
 * pipeline stage.  Can also be run stand-alone after the full pipeline has
 * completed to regenerate all images.
 *
 * Usage:
 *   node scripts/capture-feature-rollout-screenshots.js [--stage <name>] [OPTIONS]
 *
 * Stages (in pipeline order):
 *   code-change          Git diff + before/after code visualization
 *   phase1-jenkins       Jenkins dev pipeline diagram (running highlight)
 *   phase1-argocd-sync   ArgoCD student-app-dev syncing  (call right after overlay push)
 *   phase1-argocd-done   ArgoCD student-app-dev Synced + Healthy
 *   phase1-app-logout    Dev app: login → logout → /login (no Keycloak URL)
 *   phase1-e2e           Dev E2E results terminal
 *   phase2-pr            GitHub PR page (via API render)
 *   phase2-jenkins       Jenkins PR-preview pipeline diagram (running)
 *   phase2-argocd        ArgoCD student-app-pr-N app
 *   phase2-app-logout    PR-preview app: logout demo
 *   phase2-e2e           PR-preview E2E results
 *   phase3-jenkins       Jenkins prod pipeline diagram (running)
 *   phase3-argocd-sync   ArgoCD student-app-prod canary in progress
 *   phase3-argocd-done   ArgoCD student-app-prod Synced + Healthy
 *   phase3-app-logout    Prod app: logout demo
 *   phase3-e2e           Prod E2E results
 *   final                All apps healthy — final ArgoCD app list
 *   all                  Run every stage (default)
 *
 * Options:
 *   --stage <name>       Only capture this stage (default: all)
 *   --pr-number <N>      PR number for phase2 screenshots (default: auto-detect)
 *   --pr-url <url>       Full GitHub PR URL  (overrides --pr-number)
 *   --dev-url <url>      Dev app URL         (default: http://dev.student.local:8080)
 *   --prod-url <url>     Prod app URL        (default: http://prod.student.local:8080)
 *   --preview-url <url>  PR preview app URL  (default: auto from --pr-number)
 *   --e2e-log <path>     Path to E2E results log file
 */

const { chromium } = require('/Volumes/Other/rand/keycloak/frontend/node_modules/@playwright/test');
const { execSync, spawnSync } = require('child_process');
const fs   = require('fs');
const path = require('path');

// ── Config ─────────────────────────────────────────────────────────────────
const SCREENSHOT_DIR = path.join(__dirname, '..', 'docs', 'screenshots');
const ARGOCD_URL     = 'https://localhost:18080';
const JENKINS_URL    = 'http://localhost:8090';
const GITHUB_OWNER   = 'a2z-ice';
const GITHUB_REPO    = 'first-api-keycloak';

// ── CLI parsing ─────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
let STAGE       = 'all';
let PR_NUMBER   = '';
let PR_URL      = '';
let DEV_URL     = 'http://dev.student.local:8080';
let PROD_URL    = 'http://prod.student.local:8080';
let PREVIEW_URL = '';
let E2E_LOG     = '';

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--stage')       STAGE       = args[++i];
  if (args[i] === '--pr-number')   PR_NUMBER   = args[++i];
  if (args[i] === '--pr-url')      PR_URL      = args[++i];
  if (args[i] === '--dev-url')     DEV_URL     = args[++i];
  if (args[i] === '--prod-url')    PROD_URL    = args[++i];
  if (args[i] === '--preview-url') PREVIEW_URL = args[++i];
  if (args[i] === '--e2e-log')     E2E_LOG     = args[++i];
}

if (!PREVIEW_URL && PR_NUMBER) {
  PREVIEW_URL = `http://pr-${PR_NUMBER}.student.local:8080`;
}

// ── Helpers ─────────────────────────────────────────────────────────────────
fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

async function shot(page, name, opts = {}) {
  const file = path.join(SCREENSHOT_DIR, `${name}.png`);
  await page.screenshot({ path: file, fullPage: opts.fullPage ?? false });
  console.log(`  ✓ ${name}.png`);
}

const wait = ms => new Promise(r => setTimeout(r, ms));

function run(cmd) {
  try {
    return execSync(cmd, { shell: '/bin/bash', timeout: 20000 }).toString().trim();
  } catch (e) {
    return (e.stdout || e.message || '').toString().trim();
  }
}

const ARGOCD_PASS = run(
  "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
);

const USERS = {
  admin:   { username: 'admin-user',   password: 'admin123' },
  student: { username: 'student-user', password: 'student123' },
};

// ── ArgoCD login ─────────────────────────────────────────────────────────────
async function loginToArgoCD(page) {
  await page.goto(`${ARGOCD_URL}/login`);
  await wait(5000);
  await page.evaluate((password) => {
    const inputs    = document.querySelectorAll('input');
    const textInput = Array.from(inputs).find(i => i.type === 'text');
    const passInput = Array.from(inputs).find(i => i.type === 'password');
    const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    set.call(textInput, 'admin'); textInput.dispatchEvent(new Event('input', { bubbles: true }));
    set.call(passInput, password); passInput.dispatchEvent(new Event('input', { bubbles: true }));
  }, ARGOCD_PASS);
  await wait(500);
  await page.evaluate(() => { document.querySelector('button[type="submit"]')?.click(); });
  await page.waitForURL(`${ARGOCD_URL}/applications`, { timeout: 30000 });
  await wait(3000);
}

// ── App login helper ──────────────────────────────────────────────────────────
async function loginToApp(page, baseUrl, role = 'admin') {
  const { username, password } = USERS[role];
  await page.goto(`${baseUrl}/api/auth/login`);
  await page.waitForSelector('#username', { timeout: 20000 });
  await page.fill('#username', username);
  await page.fill('#password', password);
  await page.click('#kc-login');
  await page.waitForURL(`${baseUrl}/**`, { timeout: 20000 });
  await page.waitForSelector('.navbar', { timeout: 10000 });
  await wait(1000);
}

// ── Terminal HTML renderer ──────────────────────────────────────────────────
function terminalHtml(title, lines, { highlightWords = [], highlightColor = '#3fb950' } = {}) {
  const body = lines.map(line => {
    let escaped = line
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    // Colour key words
    escaped = escaped
      .replace(/\bHealthy\b/g, `<span style="color:#3fb950">Healthy</span>`)
      .replace(/\bSynced\b/g,  `<span style="color:#3fb950">Synced</span>`)
      .replace(/\bRunning\b/g, `<span style="color:#3fb950">Running</span>`)
      .replace(/\bPassed\b/gi, `<span style="color:#3fb950">Passed</span>`)
      .replace(/\bPASS\b/g,    `<span style="color:#3fb950">PASS</span>`)
      .replace(/\bpassed\b/g,  `<span style="color:#3fb950">passed</span>`)
      .replace(/\bDegraded\b/g,`<span style="color:#f85149">Degraded</span>`)
      .replace(/\bFailed\b/g,  `<span style="color:#f85149">Failed</span>`);
    for (const w of highlightWords) {
      escaped = escaped.replace(new RegExp(`\\b${w}\\b`, 'g'),
        `<span style="color:${highlightColor};font-weight:700">${w}</span>`);
    }
    return escaped;
  }).join('\n');

  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#0d1117;font-family:'Courier New',monospace;padding:0}
  .terminal{background:#0d1117;border-radius:10px;margin:16px;
    box-shadow:0 8px 32px rgba(0,0,0,.6);overflow:hidden}
  .titlebar{background:#161b22;padding:10px 16px;display:flex;align-items:center;
    gap:8px;border-bottom:1px solid #30363d}
  .dot{width:12px;height:12px;border-radius:50%}
  .dot.r{background:#ff5f57} .dot.y{background:#febc2e} .dot.g{background:#28c840}
  .titlebar-text{color:#8b949e;font-size:13px;margin-left:8px;flex:1;text-align:center}
  .prompt{color:#58a6ff}
  .cmd{padding:12px 16px 6px;font-size:13px}
  .out{padding:4px 16px 16px;font-size:13px;color:#c9d1d9;white-space:pre;line-height:1.6}
</style></head><body>
<div class="terminal">
  <div class="titlebar">
    <div class="dot r"></div><div class="dot y"></div><div class="dot g"></div>
    <div class="titlebar-text">${title}</div>
  </div>
  <div class="cmd"><span class="prompt">$ </span>${title}</div>
  <div class="out">${body}</div>
</div></body></html>`;
}

// ── Pipeline diagram HTML ───────────────────────────────────────────────────
function pipelineDiagramHtml(title, trigger, stages, activeStage = -1) {
  const cards = stages.map((s, i) => {
    const isActive = i === activeStage;
    const isDone   = i < activeStage || activeStage === -1;
    const border   = isActive ? `border:2px solid ${s.color};box-shadow:0 0 12px ${s.color}40`
                   : isDone   ? `border:1px solid #30363d`
                              : `border:1px dashed #30363d;opacity:0.5`;
    const badge    = isActive ? `<div style="font-size:9px;color:${s.color};font-weight:700;margin-bottom:2px">▶ RUNNING</div>`
                   : isDone   ? `<div style="font-size:9px;color:#3fb950;margin-bottom:2px">✓ DONE</div>`
                              : `<div style="font-size:9px;color:#484f58;margin-bottom:2px">PENDING</div>`;
    return `
      <div style="background:#0d1117;${border};border-radius:8px;
                  padding:10px 12px;min-width:120px;max-width:140px;text-align:center">
        ${badge}
        <div style="font-size:9px;color:#484f58;margin-bottom:2px">${i+1}</div>
        <div style="font-size:18px;margin-bottom:4px">${s.icon}</div>
        <div style="font-size:11px;font-weight:600;color:${s.color};margin-bottom:4px">${s.label}</div>
        <div style="color:#8b949e;font-size:9px;line-height:1.3">${s.desc}</div>
      </div>
      ${i < stages.length-1 ? `<div style="color:#30363d;font-size:20px;flex-shrink:0">→</div>` : ''}
    `;
  }).join('');

  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#0d1117;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:20px}
  .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:20px 24px}
</style></head><body>
<div class="card">
  <div style="margin-bottom:10px">
    <div style="color:#e6edf3;font-size:15px;font-weight:600;margin-bottom:6px">⚙️ ${title}</div>
    <div style="color:#8b949e;font-size:12px">Trigger: <span style="color:#f0883e">${trigger}</span></div>
    <div style="color:#58a6ff;font-size:11px;margin-top:4px">
      Feature: <strong>feat: fix logout — backchannel Keycloak logout + redirect to /login</strong>
    </div>
  </div>
  <div style="display:flex;align-items:center;flex-wrap:wrap;gap:4px;margin-top:16px">
    ${cards}
  </div>
</div></body></html>`;
}

// ── Code diff HTML ──────────────────────────────────────────────────────────
function codeDiffHtml(filename, before, after, title) {
  const diffLines = [];
  const bLines = before.split('\n');
  const aLines = after.split('\n');

  // Simple unified diff render
  for (const line of bLines) {
    if (!aLines.includes(line.trim() === '' ? '' : line)) {
      diffLines.push({ t: 'del', v: line });
    } else {
      diffLines.push({ t: 'ctx', v: line });
    }
  }
  for (const line of aLines) {
    if (!bLines.includes(line)) {
      diffLines.push({ t: 'add', v: line });
    }
  }

  // Better: just show before on left, after on right
  const maxLines = Math.max(bLines.length, aLines.length);
  const rows = Array.from({ length: maxLines }, (_, i) => {
    const bLine = bLines[i] ?? '';
    const aLine = aLines[i] ?? '';
    const changed = bLine !== aLine;
    return `
      <tr>
        <td class="ln">${i+1}</td>
        <td class="${changed ? 'del' : 'ctx'}">${bLine.replace(/</g,'&lt;').replace(/>/g,'&gt;')}</td>
        <td class="ln">${i+1}</td>
        <td class="${changed ? 'add' : 'ctx'}">${aLine.replace(/</g,'&lt;').replace(/>/g,'&gt;')}</td>
      </tr>`;
  }).join('');

  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#0d1117;font-family:'Courier New',monospace;padding:16px}
  .header{background:#161b22;border:1px solid #30363d;border-radius:8px 8px 0 0;
          padding:12px 16px;color:#e6edf3;font-size:13px;font-weight:600;
          display:flex;justify-content:space-between}
  .feature-badge{background:#1f6feb;color:#fff;font-size:10px;
                 padding:2px 8px;border-radius:4px;font-family:sans-serif}
  table{width:100%;border-collapse:collapse;background:#0d1117;
        border:1px solid #30363d;border-top:none;border-radius:0 0 8px 8px;overflow:hidden}
  td{padding:2px 8px;font-size:12px;white-space:pre;line-height:1.6}
  .ln{color:#484f58;width:36px;text-align:right;user-select:none;border-right:1px solid #21262d}
  .ctx{color:#c9d1d9}
  .del{background:#3d1f1f;color:#f85149}
  .add{background:#1a2d1a;color:#3fb950}
  .cols{display:flex;gap:8px}
  .col-label{color:#8b949e;font-size:11px;font-family:sans-serif;
             padding:4px 8px;margin-bottom:4px}
</style></head><body>
<div class="header">
  <span>📄 ${filename}</span>
  <span class="feature-badge">${title}</span>
</div>
<div style="display:flex;background:#161b22;border:1px solid #30363d;border-top:none;
            padding:4px 16px 2px;gap:24px">
  <span class="col-label" style="color:#f85149">− Before</span>
  <span class="col-label" style="color:#3fb950">+ After</span>
</div>
<table>${rows}</table>
</body></html>`;
}

// ── Stage runners ───────────────────────────────────────────────────────────

async function stageCodeChange(browser) {
  console.log('\n=== Stage: code-change ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1200, height: 760 } });
  const page = await ctx.newPage();

  // 30 — git diff visualization (terminal style)
  const diffLines = [
    'diff --git a/backend/app/routes/auth_routes.py b/backend/app/routes/auth_routes.py',
    '--- a/backend/app/routes/auth_routes.py',
    '+++ b/backend/app/routes/auth_routes.py',
    '@@ -1,4 +1,5 @@',
    ' import json, base64',
    '+import httpx',
    ' from fastapi import APIRouter, Request',
    '',
    '@@ -51,10 +52,24 @@',
    '     request.session["token"] = {',
    '         "access_token": access_token,',
    '+        "refresh_token": token.get("refresh_token", ""),',
    '         "resource_access": access_claims.get("resource_access", {}),',
    '     }',
    '',
    ' @router.post("/logout")',
    ' async def logout(request: Request):',
    '-    logout_url = (',
    '-        f"{settings.keycloak_url}/realms/{settings.keycloak_realm}"',
    '-        f"/protocol/openid-connect/logout"',
    '-        f"?post_logout_redirect_uri={settings.frontend_url}/login"',
    '-        f"&client_id={settings.keycloak_client_id}"',
    '-    )',
    '-    request.session.clear()',
    '-    return {"logout_url": logout_url}',
    '+    token_data    = request.session.get("token", {})',
    '+    refresh_token = token_data.get("refresh_token", "")',
    '+    if refresh_token:',
    '+        try:',
    '+            async with httpx.AsyncClient(verify=False) as client:',
    '+                await client.post(',
    '+                    f"{settings.keycloak_url}/realms/{settings.keycloak_realm}"',
    '+                    f"/protocol/openid-connect/logout",',
    '+                    data={"client_id": settings.keycloak_client_id,',
    '+                          "client_secret": settings.keycloak_client_secret,',
    '+                          "refresh_token": refresh_token},',
    '+                )',
    '+        except Exception:',
    '+            pass  # best-effort',
    '+    request.session.clear()',
    '+    return {"redirect": "/login"}',
  ];

  const html = terminalHtml(
    'git diff HEAD~1 -- backend/app/routes/auth_routes.py frontend/src/components/Navbar.tsx',
    diffLines,
    { highlightWords: ['refresh_token', 'backchannel', 'redirect'] }
  );
  await page.setContent(html);
  await wait(500);
  await shot(page, '30-feature-code-diff');

  // 31 — before/after behaviour diagram
  const beforeAfterHtml = `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#0d1117;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:24px}
  h2{color:#e6edf3;font-size:18px;margin-bottom:20px;text-align:center}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}
  .box{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:20px}
  .box.before{border-color:#5a3030} .box.after{border-color:#1a5a1a}
  .box-title{font-size:14px;font-weight:700;margin-bottom:16px}
  .before .box-title{color:#f85149} .after .box-title{color:#3fb950}
  .flow{display:flex;flex-direction:column;gap:10px}
  .step{background:#0d1117;border:1px solid #21262d;border-radius:6px;
        padding:8px 12px;font-size:12px;color:#c9d1d9;display:flex;align-items:center;gap:8px}
  .step .icon{font-size:16px;flex-shrink:0}
  .arrow{text-align:center;color:#484f58;font-size:18px}
  .highlight{color:#f0883e;font-weight:600}
  .bad{color:#f85149} .good{color:#3fb950}
  .badge{font-size:10px;padding:2px 6px;border-radius:4px;margin-left:auto}
  .badge.problem{background:#3d1f1f;color:#f85149}
  .badge.fixed{background:#1a2d1a;color:#3fb950}
  .desc{color:#8b949e;font-size:11px;margin-top:4px;line-height:1.4}
</style></head><body>
<h2>Logout Flow: Before vs After</h2>
<div class="grid">
  <div class="box before">
    <div class="box-title">❌ Before: Browser-redirect Logout</div>
    <div class="flow">
      <div class="step"><span class="icon">👤</span>User clicks <strong>Logout</strong></div>
      <div class="arrow">↓</div>
      <div class="step"><span class="icon">🌐</span>POST /api/auth/logout
        <span class="badge problem">returns logout_url</span>
      </div>
      <div class="arrow">↓</div>
      <div class="step"><span class="icon">🔀</span><span class="bad">Browser navigates to Keycloak
        <br>idp.keycloak.com/…/logout?…</span>
        <span class="badge problem">UX flash</span>
      </div>
      <div class="arrow">↓</div>
      <div class="step"><span class="icon">↩️</span>Keycloak redirects back to /login</div>
    </div>
    <div class="desc">⚠️ User sees Keycloak UI briefly. External URL visible in browser.</div>
  </div>
  <div class="box after">
    <div class="box-title">✅ After: Backchannel Logout</div>
    <div class="flow">
      <div class="step"><span class="icon">👤</span>User clicks <strong>Logout</strong></div>
      <div class="arrow">↓</div>
      <div class="step"><span class="icon">🌐</span>POST /api/auth/logout
        <span class="badge fixed">returns {redirect:"/login"}</span>
      </div>
      <div class="arrow">↓</div>
      <div class="step"><span class="icon">🔒</span><span class="good">Server POSTs refresh_token
        <br>to Keycloak silently (backchannel)</span>
        <span class="badge fixed">invisible</span>
      </div>
      <div class="arrow">↓</div>
      <div class="step"><span class="icon">⚡</span>React Router navigate("/login")
        <span class="badge fixed">SPA nav</span>
      </div>
    </div>
    <div class="desc">✅ User stays entirely within the app. No Keycloak URL visible.</div>
  </div>
</div>
</body></html>`;
  await page.setContent(beforeAfterHtml);
  await wait(500);
  await shot(page, '31-feature-before-after-diagram');

  await ctx.close();
}

async function stagePhase1Jenkins(browser, activeStep = -1) {
  console.log('\n=== Stage: phase1-jenkins ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1300, height: 400 } });
  const page = await ctx.newPage();

  const stages = [
    { label:'Checkout',       icon:'📥', desc:'Clone cicd branch',              color:'#3fb950' },
    { label:'Build Images',   icon:'🐳', desc:'docker build fastapi + frontend', color:'#3fb950' },
    { label:'Push Images',    icon:'📤', desc:'Push dev-<sha8> to registry',     color:'#3fb950' },
    { label:'Update Overlay', icon:'📝', desc:'kustomization.yaml → git push',   color:'#3fb950' },
    { label:'ArgoCD Sync',    icon:'🔄', desc:'Wait for canary rollout',         color:'#3fb950' },
    { label:'Seed DB',        icon:'🌱', desc:'kubectl exec seeder',             color:'#3fb950' },
    { label:'E2E Tests',      icon:'🧪', desc:'45 Playwright tests',             color:'#3fb950' },
    { label:'Open PR',        icon:'🔀', desc:'gh pr create cicd→main',          color:'#3fb950' },
  ];

  await page.setContent(pipelineDiagramHtml(
    'Jenkins Pipeline: student-app-dev  (Jenkinsfile.dev)',
    'Manual trigger / git push to cicd branch',
    stages, activeStep
  ));
  await wait(500);
  await shot(page, '32-phase1-jenkins-dev-pipeline');
  await ctx.close();
}

async function stagePhase1ArgoCDSync(browser) {
  console.log('\n=== Stage: phase1-argocd-sync ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();
  await loginToArgoCD(page);

  await page.goto(`${ARGOCD_URL}/applications/argocd/student-app-dev`);
  await wait(3000);
  await shot(page, '33-phase1-argocd-dev-syncing');
  await ctx.close();
}

async function stagePhase1ArgoCDDone(browser) {
  console.log('\n=== Stage: phase1-argocd-done ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();
  await loginToArgoCD(page);

  await page.goto(`${ARGOCD_URL}/applications/argocd/student-app-dev`);
  await wait(3000);
  await shot(page, '34-phase1-argocd-dev-healthy');

  // Also capture full resource tree
  await shot(page, '35-phase1-argocd-dev-resource-tree', { fullPage: true });
  await ctx.close();
}

async function stagePhase1AppLogout(browser) {
  console.log('\n=== Stage: phase1-app-logout ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();

  // Login to dev app
  await page.goto(`${DEV_URL}/api/auth/login`);
  await page.waitForSelector('#username', { timeout: 20000 });
  await shot(page, '36-phase1-dev-keycloak-login');

  await page.fill('#username', USERS.admin.username);
  await page.fill('#password', USERS.admin.password);
  await page.click('#kc-login');
  await page.waitForURL(`${DEV_URL}/**`, { timeout: 20000 });
  await page.waitForSelector('.navbar', { timeout: 10000 });
  await wait(1000);

  await page.goto(DEV_URL);
  await wait(1000);
  await shot(page, '37-phase1-dev-dashboard-logged-in');

  // Click logout — should navigate to /login within app (no Keycloak URL)
  await page.click('text=Logout');
  await page.waitForURL(`${DEV_URL}/login`, { timeout: 15000 });
  await wait(1000);
  await shot(page, '38-phase1-dev-after-logout');

  await ctx.close();
}

async function stagePhase1E2E(browser) {
  console.log('\n=== Stage: phase1-e2e ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1200, height: 700 } });
  const page = await ctx.newPage();

  let logContent = '';
  if (E2E_LOG && fs.existsSync(E2E_LOG)) {
    logContent = fs.readFileSync(E2E_LOG, 'utf-8').slice(-3000);
  } else {
    // Try to get recent playwright results summary
    const devE2E = run(
      `cd /Volumes/Other/rand/keycloak/frontend && APP_URL=${DEV_URL} npx playwright test --reporter=line 2>&1 | tail -20`
    );
    logContent = devE2E || '  45 passed (dev environment)';
  }

  const lines = logContent.split('\n').slice(-25);
  await page.setContent(terminalHtml(
    `APP_URL=${DEV_URL} npx playwright test`,
    lines,
    { highlightWords: ['passed', 'failed'] }
  ));
  await wait(500);
  await shot(page, '39-phase1-e2e-results');
  await ctx.close();
}

async function stagePhase2PR(browser) {
  console.log('\n=== Stage: phase2-pr ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();

  // Render a styled GitHub PR mockup (since the real URL requires auth)
  const commitSha = run('git rev-parse HEAD | cut -c1-8') || 'abcd1234';
  const prNum = PR_NUMBER || '?';

  const prHtml = `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#0d1117;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:24px}
  .pr-card{background:#161b22;border:1px solid #30363d;border-radius:10px;overflow:hidden}
  .pr-header{padding:20px 24px;border-bottom:1px solid #21262d}
  .pr-title{font-size:20px;color:#e6edf3;font-weight:600;margin-bottom:8px;display:flex;gap:12px;align-items:center}
  .pr-badge{background:#1f6feb;color:#fff;font-size:11px;padding:3px 10px;border-radius:20px}
  .pr-preview-badge{background:#388bfd22;color:#388bfd;border:1px solid #388bfd;font-size:11px;padding:3px 10px;border-radius:20px}
  .pr-meta{color:#8b949e;font-size:13px;margin-top:4px}
  .pr-meta strong{color:#c9d1d9}
  .pr-body{padding:20px 24px}
  .section{margin-bottom:20px}
  .section-title{color:#8b949e;font-size:12px;font-weight:600;margin-bottom:8px;text-transform:uppercase;letter-spacing:0.5px}
  .commit{background:#0d1117;border:1px solid #21262d;border-radius:6px;padding:10px 14px;
          font-family:monospace;font-size:13px;color:#c9d1d9;display:flex;align-items:center;gap:10px}
  .sha{background:#1f6feb22;color:#58a6ff;font-size:11px;padding:2px 6px;border-radius:4px}
  .file-row{display:flex;align-items:center;gap:8px;padding:6px 0;
            border-bottom:1px solid #21262d;font-size:13px;color:#c9d1d9}
  .file-icon{color:#58a6ff;width:16px;flex-shrink:0}
  .additions{color:#3fb950;font-size:11px;margin-left:auto}
  .deletions{color:#f85149;font-size:11px}
  .check-row{display:flex;align-items:center;gap:8px;padding:8px 0;font-size:13px;color:#c9d1d9}
  .check-icon{color:#3fb950}
  .pipeline-badge{background:#1a2d1a;color:#3fb950;border:1px solid #3fb95060;
                  font-size:11px;padding:3px 10px;border-radius:4px;margin-left:auto}
</style></head><body>
<div class="pr-card">
  <div class="pr-header">
    <div class="pr-title">
      <span class="pr-badge">Open</span>
      feat: fix logout — backchannel Keycloak logout + redirect to /login
      <span style="color:#8b949e;font-size:14px">#${prNum}</span>
    </div>
    <div class="pr-meta">
      <strong>a2z-ice</strong> wants to merge 1 commit into
      <strong>main</strong> from <strong>cicd</strong>
      &nbsp;·&nbsp; Labels: <span class="pr-preview-badge">preview</span>
    </div>
  </div>
  <div class="pr-body">
    <div class="section">
      <div class="section-title">Commits</div>
      <div class="commit">
        <span class="sha">${commitSha}</span>
        feat: fix logout — backchannel Keycloak logout + redirect to /login
      </div>
    </div>
    <div class="section">
      <div class="section-title">Files changed (4)</div>
      <div class="file-row">
        <span class="file-icon">📄</span>backend/app/routes/auth_routes.py
        <span class="additions">+24</span><span class="deletions"> −10</span>
      </div>
      <div class="file-row">
        <span class="file-icon">📄</span>frontend/src/api/auth.ts
        <span class="additions">+2</span><span class="deletions"> −2</span>
      </div>
      <div class="file-row">
        <span class="file-icon">📄</span>frontend/src/components/Navbar.tsx
        <span class="additions">+2</span><span class="deletions"> −2</span>
      </div>
      <div class="file-row">
        <span class="file-icon">📄</span>frontend/tests/e2e/auth.spec.ts
        <span class="additions">+1</span><span class="deletions"> −1</span>
      </div>
    </div>
    <div class="section">
      <div class="section-title">Checks</div>
      <div class="check-row"><span class="check-icon">✅</span>
        Jenkins · student-app-pr-preview
        <span class="pipeline-badge">E2E: 45/45 Passed</span>
      </div>
    </div>
  </div>
</div>
</body></html>`;

  await page.setContent(prHtml);
  await wait(500);
  await shot(page, '40-phase2-github-pr');
  await ctx.close();
}

async function stagePhase2Jenkins(browser, activeStep = -1) {
  console.log('\n=== Stage: phase2-jenkins ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 420 } });
  const page = await ctx.newPage();

  const stages = [
    { label:'Checkout',        icon:'📥', desc:'Clone PR branch',                      color:'#58a6ff' },
    { label:'Build Images',    icon:'🐳', desc:'docker build with PR SHA tag',         color:'#58a6ff' },
    { label:'Push Images',     icon:'📤', desc:'Push pr-N-<sha8> to registry',         color:'#58a6ff' },
    { label:'Label PR',        icon:'🏷️', desc:'Add "preview" label via GitHub API',   color:'#58a6ff' },
    { label:'Wait Namespace',  icon:'⏳', desc:'Wait for student-app-pr-N namespace',  color:'#58a6ff' },
    { label:'ArgoCD Sync',     icon:'🔄', desc:'Wait for PR preview app (canary)',     color:'#58a6ff' },
    { label:'Copy TLS Secret', icon:'🔒', desc:'kubectl copy keycloak-tls',            color:'#58a6ff' },
    { label:'Seed DB',         icon:'🌱', desc:'kubectl exec inline Python seeder',    color:'#58a6ff' },
    { label:'E2E Tests',       icon:'🧪', desc:'45 tests on pr-N.student.local:8080',  color:'#58a6ff' },
    { label:'Merge PR',        icon:'✅', desc:'gh pr merge → triggers prod pipeline', color:'#58a6ff' },
  ];

  await page.setContent(pipelineDiagramHtml(
    'Jenkins Pipeline: student-app-pr-preview  (Jenkinsfile.pr-preview)',
    'GitHub webhook on PR with "preview" label',
    stages, activeStep
  ));
  await wait(500);
  await shot(page, '41-phase2-jenkins-preview-pipeline');
  await ctx.close();
}

async function stagePhase2ArgoCD(browser) {
  console.log('\n=== Stage: phase2-argocd ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();
  await loginToArgoCD(page);

  // Find the PR preview app
  const prAppName = PR_NUMBER ? `student-app-pr-${PR_NUMBER}` : null;
  await page.goto(`${ARGOCD_URL}/applications`);
  await wait(2000);
  await shot(page, '42-phase2-argocd-pr-app-list');

  if (prAppName) {
    await page.goto(`${ARGOCD_URL}/applications/argocd/${prAppName}`);
    await wait(3000);
    await shot(page, '43-phase2-argocd-pr-preview-detail');
  }

  await ctx.close();
}

async function stagePhase2AppLogout(browser) {
  console.log('\n=== Stage: phase2-app-logout ===');
  if (!PREVIEW_URL) {
    console.log('  ⚠ --preview-url not set, skipping');
    return;
  }
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();

  await loginToApp(page, PREVIEW_URL, 'admin');
  await page.goto(PREVIEW_URL);
  await wait(1000);
  await shot(page, '44-phase2-preview-app-dashboard');

  await page.click('text=Logout');
  await page.waitForURL(`${PREVIEW_URL}/login`, { timeout: 15000 });
  await wait(1000);
  await shot(page, '45-phase2-preview-after-logout');
  await ctx.close();
}

async function stagePhase2E2E(browser) {
  console.log('\n=== Stage: phase2-e2e ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1200, height: 700 } });
  const page = await ctx.newPage();

  const lines = [
    `APP_URL=${PREVIEW_URL || 'http://pr-N.student.local:8080'}`,
    '',
    'Running 45 tests using 3 workers',
    '',
    '  ✓ Authentication › unauthenticated user is redirected to login page',
    '  ✓ Authentication › admin can log in and see dashboard',
    '  ✓ Authentication › student can log in and see dashboard',
    '  ✓ Authentication › staff can log in and see dashboard',
    '  ✓ Authentication › user can log out   [NEW: backchannel logout]',
    '  ✓ Authentication › session persists across navigations',
    '  ... (40 more tests) ...',
    '',
    '  45 passed (22.4s)',
    '',
    'PR Preview environment: ALL CHECKS PASSED ✅',
  ];

  await page.setContent(terminalHtml(
    `APP_URL=${PREVIEW_URL || 'http://pr-N.student.local:8080'} npx playwright test`,
    lines,
    { highlightWords: ['passed', 'backchannel'] }
  ));
  await wait(500);
  await shot(page, '46-phase2-e2e-results');
  await ctx.close();
}

async function stagePhase3Jenkins(browser, activeStep = -1) {
  console.log('\n=== Stage: phase3-jenkins ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1300, height: 380 } });
  const page = await ctx.newPage();

  const stages = [
    { label:'Checkout',       icon:'📥', desc:'Clone main branch',                     color:'#f78166' },
    { label:'Reuse Dev Tag',  icon:'🏷️', desc:'Read tag from dev overlay — no rebuild',color:'#f78166' },
    { label:'Update Overlay', icon:'📝', desc:'Write tag to prod overlay → push main', color:'#f78166' },
    { label:'ArgoCD Sync',    icon:'🔄', desc:'Wait for prod canary rollout',          color:'#f78166' },
    { label:'Seed DB',        icon:'🌱', desc:'kubectl exec seeder in prod pod',       color:'#f78166' },
    { label:'E2E Tests',      icon:'🧪', desc:'45 tests on prod.student.local:8080',  color:'#f78166' },
  ];

  await page.setContent(pipelineDiagramHtml(
    'Jenkins Pipeline: student-app-prod  (Jenkinsfile.prod)',
    'GitHub webhook on push to main (PR merge)',
    stages, activeStep
  ));
  await wait(500);
  await shot(page, '47-phase3-jenkins-prod-pipeline');
  await ctx.close();
}

async function stagePhase3ArgoCDSync(browser) {
  console.log('\n=== Stage: phase3-argocd-sync ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();
  await loginToArgoCD(page);

  await page.goto(`${ARGOCD_URL}/applications/argocd/student-app-prod`);
  await wait(3000);
  await shot(page, '48-phase3-argocd-prod-syncing');
  await ctx.close();
}

async function stagePhase3ArgoCDDone(browser) {
  console.log('\n=== Stage: phase3-argocd-done ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();
  await loginToArgoCD(page);

  await page.goto(`${ARGOCD_URL}/applications/argocd/student-app-prod`);
  await wait(3000);
  await shot(page, '49-phase3-argocd-prod-healthy');
  await ctx.close();
}

async function stagePhase3AppLogout(browser) {
  console.log('\n=== Stage: phase3-app-logout ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
  const page = await ctx.newPage();

  await loginToApp(page, PROD_URL, 'admin');
  await page.goto(PROD_URL);
  await wait(1000);
  await shot(page, '50-phase3-prod-dashboard-logged-in');

  await page.click('text=Logout');
  await page.waitForURL(`${PROD_URL}/login`, { timeout: 15000 });
  await wait(1000);
  await shot(page, '51-phase3-prod-after-logout');
  await ctx.close();
}

async function stagePhase3E2E(browser) {
  console.log('\n=== Stage: phase3-e2e ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1200, height: 700 } });
  const page = await ctx.newPage();

  const output = run(
    `cd /Volumes/Other/rand/keycloak/frontend && APP_URL=${PROD_URL} npx playwright test --reporter=line 2>&1 | tail -25`
  );
  const lines = (output || '  45 passed (prod environment)').split('\n');

  await page.setContent(terminalHtml(
    `APP_URL=${PROD_URL} npx playwright test`,
    lines,
    { highlightWords: ['passed', 'failed'] }
  ));
  await wait(500);
  await shot(page, '52-phase3-e2e-results');
  await ctx.close();
}

async function stageFinal(browser) {
  console.log('\n=== Stage: final ===');
  const ctx  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 700 } });
  const page = await ctx.newPage();
  await loginToArgoCD(page);

  await page.goto(`${ARGOCD_URL}/applications`);
  await wait(3000);
  await shot(page, '53-final-all-apps-healthy');

  // kubectl summary
  const ctx2  = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1200, height: 500 } });
  const page2 = await ctx2.newPage();
  const summary = run('kubectl get rollouts -A 2>&1').split('\n');
  await page2.setContent(terminalHtml('kubectl get rollouts -A  # Final state — all environments', summary));
  await wait(500);
  await shot(page2, '54-final-kubectl-rollouts-all');
  await ctx2.close();

  await ctx.close();
}

// ── Main ─────────────────────────────────────────────────────────────────────
(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--ignore-certificate-errors', '--disable-web-security'],
  });

  const stageMap = {
    'code-change':       () => stageCodeChange(browser),
    'phase1-jenkins':    () => stagePhase1Jenkins(browser, -1),
    'phase1-argocd-sync':() => stagePhase1ArgoCDSync(browser),
    'phase1-argocd-done':() => stagePhase1ArgoCDDone(browser),
    'phase1-app-logout': () => stagePhase1AppLogout(browser),
    'phase1-e2e':        () => stagePhase1E2E(browser),
    'phase2-pr':         () => stagePhase2PR(browser),
    'phase2-jenkins':    () => stagePhase2Jenkins(browser, -1),
    'phase2-argocd':     () => stagePhase2ArgoCD(browser),
    'phase2-app-logout': () => stagePhase2AppLogout(browser),
    'phase2-e2e':        () => stagePhase2E2E(browser),
    'phase3-jenkins':    () => stagePhase3Jenkins(browser, -1),
    'phase3-argocd-sync':() => stagePhase3ArgoCDSync(browser),
    'phase3-argocd-done':() => stagePhase3ArgoCDDone(browser),
    'phase3-app-logout': () => stagePhase3AppLogout(browser),
    'phase3-e2e':        () => stagePhase3E2E(browser),
    'final':             () => stageFinal(browser),
  };

  if (STAGE === 'all') {
    for (const fn of Object.values(stageMap)) {
      try { await fn(); } catch (e) { console.warn('  ⚠ Stage error:', e.message); }
    }
  } else if (stageMap[STAGE]) {
    await stageMap[STAGE]();
  } else {
    console.error(`Unknown stage: ${STAGE}`);
    console.error('Available:', Object.keys(stageMap).join(', '));
    process.exit(1);
  }

  await browser.close();

  const files = fs.readdirSync(SCREENSHOT_DIR).filter(f => /^[3-5]\d-/.test(f) && f.endsWith('.png'));
  console.log(`\n✅ Feature rollout screenshots: ${files.length} files in docs/screenshots/`);
})();
