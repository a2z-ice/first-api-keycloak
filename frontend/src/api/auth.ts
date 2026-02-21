import { apiFetch } from './client';
import type { User } from '../types';

export async function getMe(): Promise<User> {
  return apiFetch<User>('/api/auth/me');
}

export async function logout(): Promise<{ redirect: string }> {
  return apiFetch<{ redirect: string }>('/api/auth/logout', {
    method: 'POST',
  });
}
