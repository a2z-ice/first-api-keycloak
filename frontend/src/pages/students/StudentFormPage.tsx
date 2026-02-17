import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { getStudent, createStudent, updateStudent } from '../../api/students';
import { listDepartments } from '../../api/departments';
import type { Department } from '../../types';

export default function StudentFormPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const isEdit = Boolean(id);

  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [keycloakUserId, setKeycloakUserId] = useState('');
  const [departmentId, setDepartmentId] = useState<string>('');
  const [departments, setDepartments] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const load = async () => {
      try {
        const depts = await listDepartments();
        setDepartments(depts);

        if (id) {
          const student = await getStudent(Number(id));
          setName(student.name);
          setEmail(student.email);
          setKeycloakUserId(student.keycloak_user_id || '');
          setDepartmentId(student.department_id?.toString() || '');
        }
      } catch {
        // ignore
      } finally {
        setLoading(false);
      }
    };
    load();
  }, [id]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const data = {
      name,
      email,
      keycloak_user_id: keycloakUserId || undefined,
      department_id: departmentId ? Number(departmentId) : null,
    };

    try {
      if (isEdit) {
        await updateStudent(Number(id), data);
        navigate(`/students/${id}`);
      } else {
        await createStudent(data);
        navigate('/students');
      }
    } catch {
      // ignore
    }
  };

  if (loading) return <p>Loading...</p>;

  return (
    <>
      <h1>{isEdit ? 'Edit' : 'New'} Student</h1>

      <form onSubmit={handleSubmit} className="form-card">
        <div className="form-group">
          <label htmlFor="name">Name</label>
          <input
            type="text"
            id="name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
          />
        </div>

        <div className="form-group">
          <label htmlFor="email">Email</label>
          <input
            type="email"
            id="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </div>

        <div className="form-group">
          <label htmlFor="keycloak_user_id">Keycloak User ID</label>
          <input
            type="text"
            id="keycloak_user_id"
            value={keycloakUserId}
            onChange={(e) => setKeycloakUserId(e.target.value)}
          />
        </div>

        <div className="form-group">
          <label htmlFor="department_id">Department</label>
          <select
            id="department_id"
            value={departmentId}
            onChange={(e) => setDepartmentId(e.target.value)}
          >
            <option value="">-- Select Department --</option>
            {departments.map((d) => (
              <option key={d.id} value={d.id}>
                {d.name}
              </option>
            ))}
          </select>
        </div>

        <div className="form-actions">
          <button type="submit" className="btn btn-primary">
            {isEdit ? 'Update' : 'Create'}
          </button>
          <Link to="/students" className="btn btn-outline">
            Cancel
          </Link>
        </div>
      </form>
    </>
  );
}
