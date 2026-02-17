import { test, expect } from '@playwright/test';
import { login } from './helpers';

test.describe('Form Validation', () => {
  test('student form requires name', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students/new');
    await page.fill('#email', 'test@example.com');
    await page.click('button[type="submit"]');
    // HTML5 required validation prevents submit — stays on form
    await expect(page).toHaveURL(/\/students\/new/);
  });

  test('student form requires email', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students/new');
    await page.fill('#name', 'Test Name');
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/\/students\/new/);
  });

  test('department form requires name', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/departments/new');
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/\/departments\/new/);
  });
});
