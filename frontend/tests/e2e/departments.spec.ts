import { test, expect } from '@playwright/test';
import { login } from './helpers';

test.describe('Department Role-Based Access', () => {
  test('admin sees departments', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/departments');
    await expect(page.locator('td', { hasText: 'Computer Science' })).toBeVisible();
  });

  test('admin sees Add Department button', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/departments');
    await expect(page.locator('a[href="/departments/new"]')).toBeVisible();
  });

  test('staff sees departments', async ({ page }) => {
    await login(page, 'staff');
    await page.goto('/departments');
    await expect(page.locator('td', { hasText: 'Computer Science' })).toBeVisible();
  });

  test('staff does not see Add Department button', async ({ page }) => {
    await login(page, 'staff');
    await page.goto('/departments');
    await expect(page.locator('a[href="/departments/new"]')).not.toBeVisible();
  });

  test('student sees departments', async ({ page }) => {
    await login(page, 'student');
    await page.goto('/departments');
    await expect(page.locator('td', { hasText: 'Computer Science' })).toBeVisible();
  });

  test('student does not see Add Department button', async ({ page }) => {
    await login(page, 'student');
    await page.goto('/departments');
    await expect(page.locator('a[href="/departments/new"]')).not.toBeVisible();
  });
});

test.describe('Department CRUD', () => {
  test('admin can create a department', async ({ page }) => {
    await login(page, 'admin');
    const ts = Date.now().toString();
    await page.goto('/departments/new');
    await page.fill('#name', `Test Dept ${ts}`);
    await page.fill('#description', 'A test department for E2E');
    await page.click('button[type="submit"]');

    await page.waitForURL(/\/departments$/, { timeout: 10000 });
    await expect(page.locator('td', { hasText: `Test Dept ${ts}` })).toBeVisible();
  });

  test('admin can view department detail', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/departments');
    await page.locator('a:has-text("View")').first().click();
    await expect(page.locator('dt', { hasText: 'Name' })).toBeVisible();
  });

  test('admin can edit a department', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/departments');
    await page.locator('a:has-text("Edit")').first().click();
    await page.waitForURL(/\/departments\/\d+\/edit/, { timeout: 10000 });

    const originalName = await page.inputValue('#name');
    await page.fill('#name', 'Edited Dept Name');
    await page.click('button[type="submit"]');

    await page.waitForURL(/\/departments\/\d+$/, { timeout: 10000 });
    await expect(page.locator('dd', { hasText: 'Edited Dept Name' })).toBeVisible();

    // Restore
    await page.locator('a:has-text("Edit")').click();
    await page.fill('#name', originalName);
    await page.click('button[type="submit"]');
  });

  test('staff cannot access department create form', async ({ page }) => {
    await login(page, 'staff');
    await page.goto('/departments/new');
    await expect(page.locator('text=403')).toBeVisible();
  });

  test('student cannot access department create form', async ({ page }) => {
    await login(page, 'student');
    await page.goto('/departments/new');
    await expect(page.locator('text=403')).toBeVisible();
  });
});
