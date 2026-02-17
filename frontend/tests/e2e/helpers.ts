import { type Page } from '@playwright/test';

export const USERS = {
  admin: { username: 'admin-user', password: 'admin123' },
  student: { username: 'student-user', password: 'student123' },
  staff: { username: 'staff-user', password: 'staff123' },
} as const;

export async function login(page: Page, role: keyof typeof USERS) {
  const { username, password } = USERS[role];
  await page.goto('/api/auth/login');

  // Wait for Keycloak login page
  await page.waitForSelector('#username', { timeout: 15000 });

  await page.fill('#username', username);
  await page.fill('#password', password);
  await page.click('#kc-login');

  // Wait for redirect back to app and auth to complete
  await page.waitForURL('**/', { timeout: 15000 });
  // Wait for the auth context to load user data
  await page.waitForSelector('.navbar .badge, .login-container', { timeout: 10000 });
}
