import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { listDepartments } from '../../api/departments';
import type { Department } from '../../types';

export default function DepartmentListPage() {
  const { user } = useAuth();
  const [departments, setDepartments] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const isAdmin = user?.roles.includes('admin') ?? false;

  useEffect(() => {
    listDepartments()
      .then(setDepartments)
      .catch(() => setDepartments([]))
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <p>Loading...</p>;

  return (
    <>
      <div className="page-header">
        <h1>Departments</h1>
        {isAdmin && (
          <Link to="/departments/new" className="btn btn-primary">
            Add Department
          </Link>
        )}
      </div>

      {departments.length > 0 ? (
        <table className="data-table">
          <thead>
            <tr>
              <th>ID</th>
              <th>Name</th>
              <th>Description</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {departments.map((d) => (
              <tr key={d.id}>
                <td>{d.id}</td>
                <td>{d.name}</td>
                <td>{d.description || '-'}</td>
                <td>
                  <Link to={`/departments/${d.id}`} className="btn btn-sm">
                    View
                  </Link>
                  {isAdmin && (
                    <Link
                      to={`/departments/${d.id}/edit`}
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
        <p className="empty-state">No departments found.</p>
      )}
    </>
  );
}
