import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { getDepartment, createDepartment, updateDepartment } from '../../api/departments';

export default function DepartmentFormPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const isEdit = Boolean(id);

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (id) {
      getDepartment(Number(id))
        .then((dept) => {
          setName(dept.name);
          setDescription(dept.description || '');
        })
        .catch(() => {})
        .finally(() => setLoading(false));
    } else {
      setLoading(false);
    }
  }, [id]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const data = { name, description: description || undefined };

    try {
      if (isEdit) {
        await updateDepartment(Number(id), data);
        navigate(`/departments/${id}`);
      } else {
        await createDepartment(data);
        navigate('/departments');
      }
    } catch {
      // ignore
    }
  };

  if (loading) return <p>Loading...</p>;

  return (
    <>
      <h1>{isEdit ? 'Edit' : 'New'} Department</h1>

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
          <label htmlFor="description">Description</label>
          <textarea
            id="description"
            rows={3}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>

        <div className="form-actions">
          <button type="submit" className="btn btn-primary">
            {isEdit ? 'Update' : 'Create'}
          </button>
          <Link to="/departments" className="btn btn-outline">
            Cancel
          </Link>
        </div>
      </form>
    </>
  );
}
