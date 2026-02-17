import { test, expect } from '@playwright/test';
import { login } from './helpers';

test.describe('Dark Mode', () => {
  test('dark mode toggle works', async ({ page }) => {
    await login(page, 'admin');

    // Default should be light
    const html = page.locator('html');
    await expect(html).toHaveAttribute('data-theme', 'light');

    // Click toggle
    await page.click('.theme-toggle');
    await expect(html).toHaveAttribute('data-theme', 'dark');

    // Click again to go back to light
    await page.click('.theme-toggle');
    await expect(html).toHaveAttribute('data-theme', 'light');
  });

  test('dark mode persists in localStorage', async ({ page }) => {
    await login(page, 'admin');

    // Toggle to dark
    await page.click('.theme-toggle');
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');

    // Check localStorage
    const theme = await page.evaluate(() => localStorage.getItem('theme'));
    expect(theme).toBe('dark');

    // Reload page - should still be dark
    await page.reload();
    await page.waitForSelector('.navbar .badge', { timeout: 10000 });
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  });

  test('dark mode applies correct CSS', async ({ page }) => {
    await login(page, 'admin');

    // Toggle to dark
    await page.click('.theme-toggle');

    // Check that body background changes to dark
    const bgColor = await page.evaluate(() => {
      return getComputedStyle(document.body).backgroundColor;
    });
    // Dark bg: #121212 = rgb(18, 18, 18)
    expect(bgColor).toBe('rgb(18, 18, 18)');
  });
});
