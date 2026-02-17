import { apiFetch } from './client';
import type { Student } from '../types';

export async function listStudents(): Promise<Student[]> {
  return apiFetch<Student[]>('/api/students/');
}

export async function getStudent(id: number): Promise<Student> {
  return apiFetch<Student>(`/api/students/${id}`);
}

export async function createStudent(data: {
  name: string;
  email: string;
  keycloak_user_id?: string;
  department_id?: number | null;
}): Promise<Student> {
  return apiFetch<Student>('/api/students/', {
    method: 'POST',
    body: JSON.stringify(data),
  });
}

export async function updateStudent(
  id: number,
  data: {
    name: string;
    email: string;
    keycloak_user_id?: string;
    department_id?: number | null;
  }
): Promise<Student> {
  return apiFetch<Student>(`/api/students/${id}`, {
    method: 'PUT',
    body: JSON.stringify(data),
  });
}
