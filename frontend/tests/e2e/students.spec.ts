import { test, expect } from '@playwright/test';
import { login } from './helpers';

test.describe('Student Role-Based Access', () => {
  test('admin sees all students', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students');
    await expect(page.locator('h1', { hasText: 'Students' })).toBeVisible();
    const table = page.locator('.data-table');
    await expect(table.locator('td', { hasText: 'Student User' })).toBeVisible();
    await expect(table.locator('td', { hasText: 'Other Student' })).toBeVisible();
  });

  test('admin sees Add Student button', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students');
    await expect(page.locator('a[href="/students/new"]')).toBeVisible();
  });

  test('admin sees Edit buttons', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students');
    const editLinks = page.locator('a:has-text("Edit")');
    await expect(editLinks.first()).toBeVisible();
  });

  test('staff sees all students', async ({ page }) => {
    await login(page, 'staff');
    await page.goto('/students');
    const table = page.locator('.data-table');
    await expect(table.locator('td', { hasText: 'Student User' })).toBeVisible();
    await expect(table.locator('td', { hasText: 'Other Student' })).toBeVisible();
  });

  test('staff does not see Add Student button', async ({ page }) => {
    await login(page, 'staff');
    await page.goto('/students');
    await expect(page.locator('a[href="/students/new"]')).not.toBeVisible();
  });

  test('staff does not see Edit buttons', async ({ page }) => {
    await login(page, 'staff');
    await page.goto('/students');
    await expect(page.locator('a:has-text("Edit")')).not.toBeVisible();
  });

  test('student sees only own record', async ({ page }) => {
    await login(page, 'student');
    await page.goto('/students');
    const body = page.locator('body');
    await expect(body.locator('td', { hasText: 'Student User' })).toBeVisible();
    await expect(body.locator('td', { hasText: 'Other Student' })).not.toBeVisible();
  });

  test('student does not see Add Student button', async ({ page }) => {
    await login(page, 'student');
    await page.goto('/students');
    await expect(page.locator('a[href="/students/new"]')).not.toBeVisible();
  });

  test('student does not see Edit buttons', async ({ page }) => {
    await login(page, 'student');
    await page.goto('/students');
    await expect(page.locator('a:has-text("Edit")')).not.toBeVisible();
  });
});

test.describe('Student CRUD', () => {
  test('admin can create a student', async ({ page }) => {
    await login(page, 'admin');
    const ts = Date.now().toString();
    await page.goto('/students/new');
    await page.fill('#name', `Test Student ${ts}`);
    await page.fill('#email', `test-${ts}@example.com`);
    await page.click('button[type="submit"]');

    await page.waitForURL(/\/students$/, { timeout: 10000 });
    await expect(page.locator('td', { hasText: `Test Student ${ts}` })).toBeVisible();
  });

  test('admin can view student detail', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students');
    await page.locator('a:has-text("View")').first().click();
    await expect(page.locator('dt', { hasText: 'Name' })).toBeVisible();
    await expect(page.locator('dt', { hasText: 'Email' })).toBeVisible();
  });

  test('admin can edit a student', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students');
    await page.locator('a:has-text("Edit")').first().click();
    await page.waitForURL(/\/students\/\d+\/edit/, { timeout: 10000 });

    const originalName = await page.inputValue('#name');
    await page.fill('#name', 'Edited Student Name');
    await page.click('button[type="submit"]');

    await page.waitForURL(/\/students\/\d+$/, { timeout: 10000 });
    await expect(page.locator('dd', { hasText: 'Edited Student Name' })).toBeVisible();

    // Restore
    await page.locator('a:has-text("Edit")').click();
    await page.fill('#name', originalName);
    await page.click('button[type="submit"]');
  });

  test('staff cannot access student create form', async ({ page }) => {
    await login(page, 'staff');
    await page.goto('/students/new');
    await expect(page.locator('text=403')).toBeVisible();
  });

  test('student cannot access student create form', async ({ page }) => {
    await login(page, 'student');
    await page.goto('/students/new');
    await expect(page.locator('text=403')).toBeVisible();
  });
});
