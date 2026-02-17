import { test, expect } from '@playwright/test';

test.describe('Fail Demo - Screenshot on Failure', () => {
  test('deliberately fails to verify screenshot capture', async ({ page }) => {
    // Navigate to the login page (this works)
    await page.goto('/');
    await page.waitForSelector('.login-container', { timeout: 15000 });

    // This assertion will FAIL — there is no element with this text
    // Playwright should capture a screenshot at the moment of failure
    await expect(
      page.locator('h1', { hasText: 'This Element Does Not Exist' })
    ).toBeVisible({ timeout: 5000 });
  });
});
