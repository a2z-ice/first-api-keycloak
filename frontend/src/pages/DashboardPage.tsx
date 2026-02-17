import { Link } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';

export default function DashboardPage() {
  const { user } = useAuth();

  return (
    <>
      <h1>Dashboard</h1>
      <p>
        Welcome, <strong>{user?.name}</strong>!
      </p>

      <div className="card-grid">
        <div className="card">
          <h3>Students</h3>
          <p>View and manage student records.</p>
          <Link to="/students" className="btn btn-primary">
            View Students
          </Link>
        </div>
        <div className="card">
          <h3>Departments</h3>
          <p>View and manage departments.</p>
          <Link to="/departments" className="btn btn-primary">
            View Departments
          </Link>
        </div>
      </div>

      <div className="info-box">
        <h3>Your Roles</h3>
        <ul>
          {user?.roles.map((role) => (
            <li key={role}>
              <span className="badge">{role}</span>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}
