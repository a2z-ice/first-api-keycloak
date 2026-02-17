import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { getStudent } from '../../api/students';
import type { Student } from '../../types';
import { ApiError } from '../../api/client';

export default function StudentDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { user } = useAuth();
  const [student, setStudent] = useState<Student | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const isAdmin = user?.roles.includes('admin') ?? false;

  useEffect(() => {
    if (!id) return;
    getStudent(Number(id))
      .then(setStudent)
      .catch((err) => {
        if (err instanceof ApiError) {
          setError(
            err.status === 404
              ? 'Student not found'
              : err.status === 403
                ? 'Access denied'
                : err.message
          );
        } else {
          setError('Failed to load student');
        }
      })
      .finally(() => setLoading(false));
  }, [id]);

  if (loading) return <p>Loading...</p>;
  if (error) return <div className="container"><h1>Error</h1><p>{error}</p></div>;
  if (!student) return null;

  return (
    <>
      <div className="page-header">
        <h1>{student.name}</h1>
        {isAdmin && (
          <Link to={`/students/${student.id}/edit`} className="btn btn-primary">
            Edit
          </Link>
        )}
      </div>

      <div className="detail-card">
        <dl>
          <dt>ID</dt>
          <dd>{student.id}</dd>
          <dt>Name</dt>
          <dd>{student.name}</dd>
          <dt>Email</dt>
          <dd>{student.email}</dd>
          <dt>Keycloak User ID</dt>
          <dd>{student.keycloak_user_id || '-'}</dd>
          <dt>Department</dt>
          <dd>{student.department_name || '-'}</dd>
        </dl>
      </div>

      <Link to="/students" className="btn btn-outline">
        Back to Students
      </Link>
    </>
  );
}
