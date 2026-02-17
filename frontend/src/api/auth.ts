import { apiFetch } from './client';
import type { User } from '../types';

export async function getMe(): Promise<User> {
  return apiFetch<User>('/api/auth/me');
}

export async function logout(): Promise<{ logout_url: string }> {
  return apiFetch<{ logout_url: string }>('/api/auth/logout', {
    method: 'POST',
  });
}
