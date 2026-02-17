import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { listStudents } from '../../api/students';
import type { Student } from '../../types';

export default function StudentListPage() {
  const { user } = useAuth();
  const [students, setStudents] = useState<Student[]>([]);
  const [loading, setLoading] = useState(true);
  const isAdmin = user?.roles.includes('admin') ?? false;

  useEffect(() => {
    listStudents()
      .then(setStudents)
      .catch(() => setStudents([]))
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <p>Loading...</p>;

  return (
    <>
      <div className="page-header">
        <h1>Students</h1>
        {isAdmin && (
          <Link to="/students/new" className="btn btn-primary">
            Add Student
          </Link>
        )}
      </div>

      {students.length > 0 ? (
        <table className="data-table">
          <thead>
            <tr>
              <th>ID</th>
              <th>Name</th>
              <th>Email</th>
              <th>Department</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {students.map((s) => (
              <tr key={s.id}>
                <td>{s.id}</td>
                <td>{s.name}</td>
                <td>{s.email}</td>
                <td>{s.department_name || '-'}</td>
                <td>
                  <Link to={`/students/${s.id}`} className="btn btn-sm">
                    View
                  </Link>
                  {isAdmin && (
                    <Link
                      to={`/students/${s.id}/edit`}
                      className="btn btn-sm btn-outline"
                    >
                      Edit
                    </Link>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <p className="empty-state">No students found.</p>
      )}
    </>
  );
}
