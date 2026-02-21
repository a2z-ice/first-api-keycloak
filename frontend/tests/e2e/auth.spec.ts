import { test, expect } from '@playwright/test';
import { login } from './helpers';

test.describe('Authentication', () => {
  test('unauthenticated user is redirected to login page', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/login/);
    await expect(page.locator('text=Login with Keycloak')).toBeVisible();
  });

  test('admin can log in and see dashboard', async ({ page }) => {
    await login(page, 'admin');
    await expect(page.locator('h1', { hasText: 'Dashboard' })).toBeVisible();
    await expect(page.locator('.navbar .badge', { hasText: 'admin' })).toBeVisible();
  });

  test('student can log in and see dashboard', async ({ page }) => {
    await login(page, 'student');
    await expect(page.locator('h1', { hasText: 'Dashboard' })).toBeVisible();
    await expect(page.locator('.navbar .badge', { hasText: 'student' })).toBeVisible();
  });

  test('staff can log in and see dashboard', async ({ page }) => {
    await login(page, 'staff');
    await expect(page.locator('h1', { hasText: 'Dashboard' })).toBeVisible();
    await expect(page.locator('.navbar .badge', { hasText: 'staff' })).toBeVisible();
  });

  test('user can log out', async ({ page }) => {
    await login(page, 'admin');
    await page.click('text=Logout');
    // After logout, backend clears session and app navigates to /login directly
    await page.waitForURL(/\/login/, { timeout: 15000 });
    // Verify session is cleared
    await page.goto('/');
    await expect(page).toHaveURL(/\/login/);
  });

  test('session persists across navigations', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students');
    await expect(page.locator('h1', { hasText: 'Students' })).toBeVisible();

    await page.goto('/departments');
    await expect(page.locator('h1', { hasText: 'Departments' })).toBeVisible();

    await page.goto('/');
    await expect(page.locator('h1', { hasText: 'Dashboard' })).toBeVisible();
    await expect(page.locator('.navbar .badge', { hasText: 'admin' })).toBeVisible();
  });

  test('session persists across multiple requests', async ({ page }) => {
    await login(page, 'admin');
    for (let i = 0; i < 5; i++) {
      await page.goto('/students');
      await expect(page.locator('h1', { hasText: 'Students' })).toBeVisible();
    }
    await page.goto('/');
    await expect(page.locator('.navbar .badge', { hasText: 'admin' })).toBeVisible();
  });
});

test.describe('Login button', () => {
  test('login page displays Login with Keycloak button', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/login/);
    const loginBtn = page.locator('a', { hasText: 'Login with Keycloak' });
    await expect(loginBtn).toBeVisible();
    await expect(loginBtn).toHaveAttribute('href', '/api/auth/login');
  });

  test('login button reaches Keycloak without server error', async ({ page }) => {
    await page.goto('/login');
    // Clicking the login button must not result in an Internal Server Error
    const [response] = await Promise.all([
      page.waitForResponse((r) => r.url().includes('/api/auth/login')),
      page.click('text=Login with Keycloak'),
    ]);
    expect(response.status()).not.toBe(500);
    // Must reach the Keycloak login form
    await expect(page.locator('#username')).toBeVisible({ timeout: 15000 });
  });
});

test.describe('Logout — session and domain', () => {
  test('logout button is visible with btn-logout class', async ({ page }) => {
    await login(page, 'admin');
    const logoutBtn = page.locator('button.btn-logout');
    await expect(logoutBtn).toBeVisible();
    await expect(logoutBtn).toContainText('Logout');
  });

  test('logout URL stays within app domain — no Keycloak redirect', async ({ page }) => {
    await login(page, 'admin');
    await page.click('button.btn-logout');
    await page.waitForURL(/\/login/, { timeout: 15000 });
    // URL must remain on the application domain, never on idp.keycloak.com
    expect(page.url()).not.toContain('idp.keycloak.com');
    expect(page.url()).toMatch(/\/login$/);
  });

  test('logout clears app session — protected routes redirect to login', async ({ page }) => {
    await login(page, 'admin');
    await expect(page.locator('.navbar .badge', { hasText: 'admin' })).toBeVisible();

    await page.click('button.btn-logout');
    await page.waitForURL(/\/login/, { timeout: 15000 });

    // Direct navigation to protected routes must require re-login
    await page.goto('/students');
    await expect(page).toHaveURL(/\/login/);

    await page.goto('/departments');
    await expect(page).toHaveURL(/\/login/);

    await page.goto('/');
    await expect(page).toHaveURL(/\/login/);
  });

  test('logout clears Keycloak session — re-login requires credentials', async ({ page }) => {
    await login(page, 'admin');
    await page.click('button.btn-logout');
    await page.waitForURL(/\/login/, { timeout: 15000 });

    // Initiate login again — backchannel logout must have cleared the Keycloak SSO session
    // so Keycloak shows the credentials form rather than auto-authenticating
    await page.goto('/api/auth/login');
    await expect(page.locator('#username')).toBeVisible({ timeout: 15000 });
    await expect(page.locator('#password')).toBeVisible();
  });

  test('logout then re-login restores full session', async ({ page }) => {
    // First session
    await login(page, 'admin');
    await expect(page.locator('h1', { hasText: 'Dashboard' })).toBeVisible();

    // Logout
    await page.click('button.btn-logout');
    await page.waitForURL(/\/login/, { timeout: 15000 });

    // Re-login — must work cleanly after session cleared
    await login(page, 'admin');
    await expect(page.locator('h1', { hasText: 'Dashboard' })).toBeVisible();
    await expect(page.locator('.navbar .badge', { hasText: 'admin' })).toBeVisible();
  });
});
