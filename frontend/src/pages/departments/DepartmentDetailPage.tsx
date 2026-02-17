import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { getDepartment } from '../../api/departments';
import type { DepartmentDetail } from '../../types';
import { ApiError } from '../../api/client';

export default function DepartmentDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { user } = useAuth();
  const [department, setDepartment] = useState<DepartmentDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const isAdmin = user?.roles.includes('admin') ?? false;

  useEffect(() => {
    if (!id) return;
    getDepartment(Number(id))
      .then(setDepartment)
      .catch((err) => {
        if (err instanceof ApiError && err.status === 404) {
          setError('Department not found');
        } else {
          setError('Failed to load department');
        }
      })
      .finally(() => setLoading(false));
  }, [id]);

  if (loading) return <p>Loading...</p>;
  if (error) return <div className="container"><h1>Error</h1><p>{error}</p></div>;
  if (!department) return null;

  return (
    <>
      <div className="page-header">
        <h1>{department.name}</h1>
        {isAdmin && (
          <Link to={`/departments/${department.id}/edit`} className="btn btn-primary">
            Edit
          </Link>
        )}
      </div>

      <div className="detail-card">
        <dl>
          <dt>ID</dt>
          <dd>{department.id}</dd>
          <dt>Name</dt>
          <dd>{department.name}</dd>
          <dt>Description</dt>
          <dd>{department.description || '-'}</dd>
          <dt>Students</dt>
          <dd>{department.student_count}</dd>
        </dl>
      </div>

      {department.students.length > 0 && (
        <>
          <h2>Students in this Department</h2>
          <table className="data-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Email</th>
              </tr>
            </thead>
            <tbody>
              {department.students.map((s) => (
                <tr key={s.id}>
                  <td>
                    <Link to={`/students/${s.id}`}>{s.name}</Link>
                  </td>
                  <td>{s.email}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}

      <Link to="/departments" className="btn btn-outline">
        Back to Departments
      </Link>
    </>
  );
}
