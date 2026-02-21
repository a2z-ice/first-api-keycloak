import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import { useTheme } from '../contexts/ThemeContext';
import { logout } from '../api/auth';

export default function Navbar() {
  const { user, refresh } = useAuth();
  const { theme, toggleTheme } = useTheme();
  const navigate = useNavigate();

  const handleLogout = async () => {
    try {
      const { redirect } = await logout();
      await refresh();
      navigate(redirect);
    } catch {
      navigate('/login');
    }
  };

  return (
    <nav className="navbar">
      <div className="nav-brand">
        <Link to="/">Student Management System</Link>
      </div>
      {user && (
        <>
          <div className="nav-links">
            <Link to="/">Home</Link>
            <Link to="/students">Students</Link>
            <Link to="/departments">Departments</Link>
          </div>
          <div className="nav-user">
            <span>
              {user.name}{' '}
              {user.roles.map((role) => (
                <span key={role} className="badge">
                  {role}
                </span>
              ))}
            </span>
            <button
              className="theme-toggle"
              onClick={toggleTheme}
              aria-label="Toggle theme"
              title={theme === 'light' ? 'Switch to dark mode' : 'Switch to light mode'}
            >
              {theme === 'light' ? '\u263E' : '\u2600'}
            </button>
            <button className="btn-logout" onClick={handleLogout}>
              Logout
            </button>
          </div>
        </>
      )}
    </nav>
  );
}
