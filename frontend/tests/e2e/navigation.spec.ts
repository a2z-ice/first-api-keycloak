import { test, expect } from '@playwright/test';
import { login } from './helpers';

test.describe('Navigation', () => {
  test('navbar has Home, Students, Departments links', async ({ page }) => {
    await login(page, 'admin');
    await expect(page.locator('.nav-links a:has-text("Home")')).toBeVisible();
    await expect(page.locator('.nav-links a:has-text("Students")')).toBeVisible();
    await expect(page.locator('.nav-links a:has-text("Departments")')).toBeVisible();
  });

  test('dashboard has Students and Departments cards', async ({ page }) => {
    await login(page, 'admin');
    await expect(page.locator('.card:has-text("Students")')).toBeVisible();
    await expect(page.locator('.card:has-text("Departments")')).toBeVisible();
  });

  test('student list to detail navigation', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students');
    await page.locator('a:has-text("View")').first().click();
    await expect(page).toHaveURL(/\/students\/\d+/);
  });

  test('department list to detail navigation', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/departments');
    await page.locator('a:has-text("View")').first().click();
    await expect(page).toHaveURL(/\/departments\/\d+/);
  });
});
