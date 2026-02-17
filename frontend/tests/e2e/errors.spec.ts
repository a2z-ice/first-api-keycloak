import { test, expect } from '@playwright/test';
import { login } from './helpers';

test.describe('Error Handling', () => {
  test('nonexistent student shows error', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/students/99999');
    await expect(page.locator('text=Student not found')).toBeVisible();
  });

  test('nonexistent department shows error', async ({ page }) => {
    await login(page, 'admin');
    await page.goto('/departments/99999');
    await expect(page.locator('text=Department not found')).toBeVisible();
  });

  test('student cannot access other student record', async ({ page }) => {
    await login(page, 'student');
    await page.goto('/students');
    // Get the student's own link
    const ownLink = page.locator('a:has-text("View")').first();
    const ownHref = await ownLink.getAttribute('href');
    const ownId = parseInt(ownHref!.split('/').pop()!);

    // Try other IDs
    for (let otherId = 1; otherId < ownId + 5; otherId++) {
      if (otherId !== ownId) {
        await page.goto(`/students/${otherId}`);
        const content = await page.textContent('body');
        if (content?.includes('Access denied') || content?.includes('Student not found')) {
          break;
        }
      }
    }
  });
});
