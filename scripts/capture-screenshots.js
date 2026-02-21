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
const JENKINS_URL = 'http://localhost:8090';
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

  console.log('\n=== Jenkins Screenshots ===');
  {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 900 } });
    const page = await ctx.newPage();

    // 20 — Jenkins dashboard (job list)
    await page.goto(`${JENKINS_URL}/`);
    await wait(2000);
    await shot(page, '20-jenkins-dashboard');

    // 21 — student-app-dev job page
    await page.goto(`${JENKINS_URL}/job/student-app-dev/`);
    await wait(2000);
    await shot(page, '21-jenkins-dev-job');

    // 22 — student-app-pr-preview job page
    await page.goto(`${JENKINS_URL}/job/student-app-pr-preview/`);
    await wait(2000);
    await shot(page, '22-jenkins-pr-preview-job');

    // 23 — student-app-prod job page
    await page.goto(`${JENKINS_URL}/job/student-app-prod/`);
    await wait(2000);
    await shot(page, '23-jenkins-prod-job');

    // 24 — Jenkins credentials page
    await page.goto(`${JENKINS_URL}/manage/credentials/store/system/domain/_/`);
    await wait(2000);
    await shot(page, '24-jenkins-credentials');

    await ctx.close();
  }

  console.log('\n=== Jenkins Pipeline Stage Diagrams ===');
  {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1300, height: 620 } });
    const page = await ctx.newPage();

    // Render pipeline stages as styled HTML cards
    const pipelines = [
      {
        name: '25-jenkins-pipeline-dev-stages',
        title: 'Jenkins Pipeline: student-app-dev (Jenkinsfile.dev)',
        trigger: 'Manual / GitHub webhook on cicd branch push',
        stages: [
          { label: 'Checkout',      icon: '📥', desc: 'Clone cicd branch from GitHub',                         color: '#3fb950' },
          { label: 'Build Images',  icon: '🐳', desc: 'docker build fastapi + frontend images',                color: '#3fb950' },
          { label: 'Push Images',   icon: '📤', desc: 'Push dev-<sha8> tags to localhost:5001 registry',       color: '#3fb950' },
          { label: 'Update Overlay',icon: '📝', desc: 'Update gitops/overlays/dev/kustomization.yaml → commit + push to dev branch', color: '#3fb950' },
          { label: 'ArgoCD Sync',   icon: '🔄', desc: 'Wait for ArgoCD to sync student-app-dev (canary rollout completes)', color: '#3fb950' },
          { label: 'Seed DB',       icon: '🌱', desc: 'kubectl exec inline Python to seed departments + students', color: '#3fb950' },
          { label: 'E2E Tests',     icon: '🧪', desc: 'Run 45 Playwright tests against dev.student.local:8080',color: '#3fb950' },
          { label: 'Open PR',       icon: '🔀', desc: 'gh pr create: cicd → main (triggers prod pipeline)',    color: '#3fb950' },
        ],
      },
      {
        name: '26-jenkins-pipeline-preview-stages',
        title: 'Jenkins Pipeline: student-app-pr-preview (Jenkinsfile.pr-preview)',
        trigger: 'GitHub webhook on PR opened (label: preview)',
        stages: [
          { label: 'Checkout',       icon: '📥', desc: 'Clone PR branch from GitHub',                               color: '#58a6ff' },
          { label: 'Build Images',   icon: '🐳', desc: 'docker build both images with PR SHA tag',                  color: '#58a6ff' },
          { label: 'Push Images',    icon: '📤', desc: 'Push pr-<N>-<sha8> tags to registry',                       color: '#58a6ff' },
          { label: 'Label PR',       icon: '🏷️', desc: 'POST /repos/{owner}/{repo}/issues/{N}/labels → "preview"', color: '#58a6ff' },
          { label: 'Wait Namespace', icon: '⏳', desc: 'Wait for ArgoCD to create student-app-pr-N namespace',      color: '#58a6ff' },
          { label: 'ArgoCD Sync',    icon: '🔄', desc: 'Wait for ArgoCD to sync PR preview app (canary)',           color: '#58a6ff' },
          { label: 'Copy TLS Secret',icon: '🔒', desc: 'kubectl copy keycloak-tls secret to PR namespace',         color: '#58a6ff' },
          { label: 'Seed DB',        icon: '🌱', desc: 'kubectl exec inline Python seeder in PR pod',               color: '#58a6ff' },
          { label: 'E2E Tests',      icon: '🧪', desc: 'Run 45 tests against pr-N.student.local:8080',             color: '#58a6ff' },
          { label: 'Merge PR',       icon: '✅', desc: 'gh pr merge → main (triggers prod pipeline)',               color: '#58a6ff' },
        ],
      },
      {
        name: '27-jenkins-pipeline-prod-stages',
        title: 'Jenkins Pipeline: student-app-prod (Jenkinsfile.prod)',
        trigger: 'GitHub webhook on push to main branch',
        stages: [
          { label: 'Checkout',       icon: '📥', desc: 'Clone main branch from GitHub',                             color: '#f78166' },
          { label: 'Reuse Dev Tag',  icon: '🏷️', desc: 'Read IMAGE_TAG from dev overlay — no rebuild',            color: '#f78166' },
          { label: 'Update Overlay', icon: '📝', desc: 'Update gitops/overlays/prod/kustomization.yaml → push main',color: '#f78166' },
          { label: 'ArgoCD Sync',    icon: '🔄', desc: 'Wait for ArgoCD to sync student-app-prod (canary rollout)',  color: '#f78166' },
          { label: 'Seed DB',        icon: '🌱', desc: 'kubectl exec inline Python seeder in prod pod',             color: '#f78166' },
          { label: 'E2E Tests',      icon: '🧪', desc: 'Run 45 Playwright tests against prod.student.local:8080',  color: '#f78166' },
        ],
      },
    ];

    for (const { name, title, trigger, stages } of pipelines) {
      const stageCards = stages.map((s, i) => `
        <div class="stage">
          <div class="stage-num">${i + 1}</div>
          <div class="stage-icon">${s.icon}</div>
          <div class="stage-label" style="color:${s.color}">${s.label}</div>
          <div class="stage-desc">${s.desc}</div>
        </div>
        ${i < stages.length - 1 ? '<div class="arrow">→</div>' : ''}
      `).join('');

      const html = `<!DOCTYPE html>
<html>
<head><meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #0d1117; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; padding: 20px; }
  .card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 12px;
    padding: 20px 24px;
  }
  .header { margin-bottom: 10px; }
  .title { color: #e6edf3; font-size: 15px; font-weight: 600; margin-bottom: 6px; }
  .trigger { color: #8b949e; font-size: 12px; }
  .trigger span { color: #f0883e; }
  .pipeline { display: flex; align-items: center; flex-wrap: wrap; gap: 4px; margin-top: 16px; }
  .stage {
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 10px 12px;
    min-width: 120px;
    max-width: 140px;
    text-align: center;
  }
  .stage-num { color: #484f58; font-size: 10px; margin-bottom: 2px; }
  .stage-icon { font-size: 18px; margin-bottom: 4px; }
  .stage-label { font-size: 12px; font-weight: 600; margin-bottom: 4px; }
  .stage-desc { color: #8b949e; font-size: 9px; line-height: 1.3; }
  .arrow { color: #30363d; font-size: 20px; flex-shrink: 0; }
  .jenkins-logo { color: #d33833; font-weight: 700; font-size: 13px; letter-spacing: 0.5px; }
</style>
</head>
<body>
<div class="card">
  <div class="header">
    <div class="title">⚙️ ${title}</div>
    <div class="trigger">Trigger: <span>${trigger}</span></div>
  </div>
  <div class="pipeline">${stageCards}</div>
</div>
</body></html>`;

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
