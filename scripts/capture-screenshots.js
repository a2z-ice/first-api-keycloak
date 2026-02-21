/**
 * capture-screenshots.js — Capture all UI screenshots for the presentation
 *
 * Usage: node scripts/capture-screenshots.js
 *
 * Captures:
 *   - ArgoCD: app list, dev app detail, prod app detail, rollout resource view
 *   - Dev app: login redirect, dashboard, students list, departments list
 *   - Prod app: dashboard, students list
 *   - Kubernetes: rollout status (via kubectl output rendered as text)
 */

const { chromium } = require('/Volumes/Other/rand/keycloak/frontend/node_modules/@playwright/test');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const SCREENSHOT_DIR = path.join(__dirname, '..', 'docs', 'screenshots');
const ARGOCD_URL  = 'https://localhost:18080';  // port-forward (ArgoCD serves HTTPS on 8080)
const DEV_URL     = 'http://dev.student.local:8080';
const PROD_URL    = 'http://prod.student.local:8080';
const KC_URL      = 'https://idp.keycloak.com:31111';

// Credentials
const ARGOCD_PASS = execSync(
  "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d",
  { shell: '/bin/bash' }
).toString().trim();

const USERS = {
  admin:   { username: 'admin-user',   password: 'admin123' },
  student: { username: 'student-user', password: 'student123' },
};

fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

async function shot(page, name, opts = {}) {
  const file = path.join(SCREENSHOT_DIR, `${name}.png`);
  await page.screenshot({ path: file, fullPage: opts.fullPage ?? false });
  console.log(`  ✓ ${name}.png`);
  return file;
}

async function wait(ms) {
  return new Promise(r => setTimeout(r, ms));
}

async function loginToApp(page, role = 'admin') {
  const { username, password } = USERS[role];
  await page.goto(`${DEV_URL}/api/auth/login`);
  await page.waitForSelector('#username', { timeout: 20000 });
  await page.fill('#username', username);
  await page.fill('#password', password);
  await page.click('#kc-login');
  await page.waitForURL(`${DEV_URL}/**`, { timeout: 20000 });
  await page.waitForSelector('.navbar', { timeout: 10000 });
}

async function loginToArgoCD(page) {
  await page.goto(`${ARGOCD_URL}/login`);
  await wait(5000);  // Wait for ArgoCD SPA to render
  // ArgoCD v3 inputs lack name attrs and Playwright strict-mode can't interact normally
  // Use React-compatible JS setter to fill inputs, then click submit
  await page.evaluate((password) => {
    const inputs = document.querySelectorAll('input');
    const textInput = Array.from(inputs).find(i => i.type === 'text');
    const passInput = Array.from(inputs).find(i => i.type === 'password');
    const nativeSet = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    nativeSet.call(textInput, 'admin');
    textInput.dispatchEvent(new Event('input', { bubbles: true }));
    nativeSet.call(passInput, password);
    passInput.dispatchEvent(new Event('input', { bubbles: true }));
  }, ARGOCD_PASS);
  await wait(500);
  await page.evaluate(() => {
    const btn = document.querySelector('button[type="submit"]');
    if (btn) btn.click();
  });
  await page.waitForURL(`${ARGOCD_URL}/applications`, { timeout: 30000 });
  await wait(3000);
}

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--ignore-certificate-errors', '--disable-web-security'],
  });

  console.log('\n=== ArgoCD Screenshots ===');
  {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
    const page = await ctx.newPage();

    await loginToArgoCD(page);

    // 01 — ArgoCD application list
    await page.goto(`${ARGOCD_URL}/applications`);
    await wait(2000);
    await shot(page, '01-argocd-app-list');

    // 02 — student-app-dev detail
    await page.goto(`${ARGOCD_URL}/applications/argocd/student-app-dev`);
    await wait(3000);
    await shot(page, '02-argocd-dev-detail');

    // 03 — student-app-dev resource tree (full page)
    await shot(page, '03-argocd-dev-resource-tree', { fullPage: true });

    // 04 — student-app-prod detail
    await page.goto(`${ARGOCD_URL}/applications/argocd/student-app-prod`);
    await wait(3000);
    await shot(page, '04-argocd-prod-detail');

    // 05 — Rollout resource in ArgoCD — click on fastapi-app Rollout
    try {
      // Find the Rollout resource node in the app detail
      await page.goto(`${ARGOCD_URL}/applications/argocd/student-app-dev`);
      await wait(3000);
      // Look for the Rollout node
      const rolloutNode = page.locator('text=fastapi-app').first();
      if (await rolloutNode.isVisible()) {
        await rolloutNode.click();
        await wait(1500);
        await shot(page, '05-argocd-rollout-resource-panel');
      }
    } catch (e) {
      console.log('  ⚠ Rollout panel click skipped:', e.message);
    }

    await ctx.close();
  }

  console.log('\n=== Dev App Screenshots (Admin) ===');
  {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
    const page = await ctx.newPage();

    // 06 — Keycloak login page (before login)
    await page.goto(`${DEV_URL}/api/auth/login`);
    await page.waitForSelector('#username', { timeout: 20000 });
    await shot(page, '06-keycloak-login-page');

    // Login as admin
    await page.fill('#username', USERS.admin.username);
    await page.fill('#password', USERS.admin.password);
    await page.click('#kc-login');
    await page.waitForURL(`${DEV_URL}/**`, { timeout: 20000 });
    await page.waitForSelector('.navbar', { timeout: 10000 });
    await wait(1000);

    // 07 — Dev dashboard (admin)
    await page.goto(DEV_URL);
    await wait(1000);
    await shot(page, '07-dev-dashboard-admin');

    // 08 — Students list (admin sees all)
    await page.goto(`${DEV_URL}/students`);
    await wait(1000);
    await shot(page, '08-dev-students-list-admin');

    // 09 — Departments list
    await page.goto(`${DEV_URL}/departments`);
    await wait(1000);
    await shot(page, '09-dev-departments-list');

    // 10 — Dark mode
    try {
      await page.goto(DEV_URL);
      await wait(500);
      const themeBtn = page.locator('button.theme-toggle, [aria-label*="theme"], [aria-label*="dark"]').first();
      if (await themeBtn.isVisible({ timeout: 3000 })) {
        await themeBtn.click();
        await wait(500);
        await shot(page, '10-dev-dashboard-dark-mode');
        await themeBtn.click(); // reset
      }
    } catch (e) {
      console.log('  ⚠ Dark mode toggle skipped:', e.message);
    }

    await ctx.close();
  }

  console.log('\n=== Dev App Screenshots (Student role) ===');
  {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
    const page = await ctx.newPage();

    await page.goto(`${DEV_URL}/api/auth/login`);
    await page.waitForSelector('#username', { timeout: 20000 });
    await page.fill('#username', USERS.student.username);
    await page.fill('#password', USERS.student.password);
    await page.click('#kc-login');
    await page.waitForURL(`${DEV_URL}/**`, { timeout: 20000 });
    await page.waitForSelector('.navbar', { timeout: 10000 });
    await wait(1000);

    // 11 — Students list (student sees own record only)
    await page.goto(`${DEV_URL}/students`);
    await wait(1000);
    await shot(page, '11-dev-students-list-student-role');

    await ctx.close();
  }

  console.log('\n=== Prod App Screenshots ===');
  {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
    const page = await ctx.newPage();

    // Need to login via prod URL
    await page.goto(`${PROD_URL}/api/auth/login`);
    await page.waitForSelector('#username', { timeout: 20000 });
    await page.fill('#username', USERS.admin.username);
    await page.fill('#password', USERS.admin.password);
    await page.click('#kc-login');
    await page.waitForURL(`${PROD_URL}/**`, { timeout: 20000 });
    await page.waitForSelector('.navbar', { timeout: 10000 });
    await wait(1000);

    // 12 — Prod dashboard
    await page.goto(PROD_URL);
    await wait(1000);
    await shot(page, '12-prod-dashboard-admin');

    // 13 — Prod students
    await page.goto(`${PROD_URL}/students`);
    await wait(1000);
    await shot(page, '13-prod-students-list');

    await ctx.close();
  }

  console.log('\n=== Kubectl Terminal Screenshots (rendered HTML) ===');
  {
    // Render kubectl output as styled HTML and screenshot it
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1200, height: 700 } });
    const page = await ctx.newPage();

    const commands = [
      {
        name: '14-kubectl-rollouts-dev',
        title: 'kubectl get rollouts -n student-app-dev',
        cmd: 'kubectl get rollouts -n student-app-dev -o wide 2>&1',
      },
      {
        name: '15-kubectl-rollouts-prod',
        title: 'kubectl get rollouts -n student-app-prod',
        cmd: 'kubectl get rollouts -n student-app-prod -o wide 2>&1',
      },
      {
        name: '16-kubectl-argocd-apps',
        title: 'kubectl get applications -n argocd',
        cmd: 'kubectl get applications -n argocd 2>&1',
      },
      {
        name: '17-kubectl-argo-rollouts-controller',
        title: 'kubectl get pods -n argo-rollouts',
        cmd: 'kubectl get pods -n argo-rollouts -o wide 2>&1',
      },
      {
        name: '18-kubectl-rollout-describe-canary',
        title: 'kubectl describe rollout fastapi-app -n student-app-dev | grep -A25 Strategy',
        cmd: 'kubectl describe rollout fastapi-app -n student-app-dev 2>&1 | grep -A 25 "Strategy:"',
      },
      {
        name: '19-rollout-crds',
        title: 'kubectl get crd | grep argoproj.io',
        cmd: "kubectl get crd 2>&1 | grep argoproj.io",
      },
    ];

    for (const { name, title, cmd } of commands) {
      let output;
      try {
        output = execSync(cmd, { shell: '/bin/bash', timeout: 15000 }).toString().trim();
      } catch (e) {
        output = e.stdout?.toString() || e.message;
      }

      const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #1a1a2e; font-family: 'Courier New', monospace; padding: 0; }
  .terminal {
    background: #0d1117;
    border-radius: 10px;
    margin: 16px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.6);
    overflow: hidden;
  }
  .titlebar {
    background: #161b22;
    padding: 10px 16px;
    display: flex;
    align-items: center;
    gap: 8px;
    border-bottom: 1px solid #30363d;
  }
  .dot { width: 12px; height: 12px; border-radius: 50%; }
  .dot.red { background: #ff5f57; }
  .dot.yellow { background: #febc2e; }
  .dot.green { background: #28c840; }
  .titlebar-text { color: #8b949e; font-size: 13px; margin-left: 8px; flex: 1; text-align: center; }
  .prompt { color: #58a6ff; }
  .cmd-line { padding: 12px 16px 6px; font-size: 13px; }
  .output { padding: 4px 16px 16px; font-size: 13px; color: #c9d1d9; white-space: pre; line-height: 1.6; }
  .output .header { color: #58a6ff; font-weight: bold; }
  .output .healthy { color: #3fb950; }
  .output .synced { color: #3fb950; }
  .output .running { color: #3fb950; }
  .output .rollout { color: #d2a8ff; }
</style>
</head>
<body>
<div class="terminal">
  <div class="titlebar">
    <div class="dot red"></div>
    <div class="dot yellow"></div>
    <div class="dot green"></div>
    <div class="titlebar-text">${title}</div>
  </div>
  <div class="cmd-line"><span class="prompt">$ </span>${title.replace(/</g,'&lt;').replace(/>/g,'&gt;')}</div>
  <div class="output">${formatOutput(output)}</div>
</div>
</body>
</html>`;

      await page.setContent(html);
      await wait(500);
      await shot(page, name);
    }

    await ctx.close();
  }

  await browser.close();

  const files = fs.readdirSync(SCREENSHOT_DIR).filter(f => f.endsWith('.png'));
  console.log(`\n✅ Captured ${files.length} screenshots in docs/screenshots/`);
  files.forEach(f => console.log(`   ${f}`));
})();

function formatOutput(text) {
  return text
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .split('\n').map((line, i) => {
      if (i === 0 && (line.includes('NAME') || line.includes('NAMESPACE'))) {
        return `<span class="header">${line}</span>`;
      }
      line = line.replace(/\bHealthy\b/g, '<span class="healthy">Healthy</span>');
      line = line.replace(/\bSynced\b/g, '<span class="synced">Synced</span>');
      line = line.replace(/\bRunning\b/g, '<span class="running">Running</span>');
      line = line.replace(/\bRollout\b/g, '<span class="rollout">Rollout</span>');
      return line;
    }).join('\n');
}
