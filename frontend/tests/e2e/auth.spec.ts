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
