export interface User {
  sub: string | null;
  email: string | null;
  name: string | null;
  preferred_username: string | null;
  roles: string[];
}

export interface Student {
  id: number;
  name: string;
  email: string;
  keycloak_user_id: string | null;
  department_id: number | null;
  department_name: string | null;
}

export interface Department {
  id: number;
  name: string;
  description: string | null;
  student_count: number;
}

export interface DepartmentDetail extends Department {
  students: Student[];
}
