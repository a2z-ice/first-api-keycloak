import { defineConfig, devices } from '@playwright/test';

/**
 * Separate Playwright config for the fail-demo test.
 * Enables screenshot capture on failure to verify reporting works.
 * Does NOT affect the main test suite (playwright.config.ts).
 */
export default defineConfig({
  testDir: './tests/e2e-fail-demo',
  fullyParallel: false,
  retries: 0,
  workers: 1,
  reporter: [
    ['html', { outputFolder: 'playwright-fail-demo-report', open: 'never' }],
    ['list'],
  ],
  use: {
    baseURL: process.env.APP_URL || 'http://localhost:30000',
    screenshot: 'only-on-failure',
    ignoreHTTPSErrors: true,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
