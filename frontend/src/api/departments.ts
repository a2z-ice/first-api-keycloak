import { apiFetch } from './client';
import type { Department, DepartmentDetail } from '../types';

export async function listDepartments(): Promise<Department[]> {
  return apiFetch<Department[]>('/api/departments/');
}

export async function getDepartment(id: number): Promise<DepartmentDetail> {
  return apiFetch<DepartmentDetail>(`/api/departments/${id}`);
}

export async function createDepartment(data: {
  name: string;
  description?: string;
}): Promise<Department> {
  return apiFetch<Department>('/api/departments/', {
    method: 'POST',
    body: JSON.stringify(data),
  });
}

export async function updateDepartment(
  id: number,
  data: { name: string; description?: string }
): Promise<Department> {
  return apiFetch<Department>(`/api/departments/${id}`, {
    method: 'PUT',
    body: JSON.stringify(data),
  });
}
