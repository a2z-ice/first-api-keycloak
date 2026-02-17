import { useAuth } from '../contexts/AuthContext';

export default function AdminRoute({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth();

  if (loading) {
    return <div className="container"><p>Loading...</p></div>;
  }

  if (!user || !user.roles.includes('admin')) {
    return (
      <div className="container">
        <h1>403 - Forbidden</h1>
        <p>You do not have permission to access this page.</p>
      </div>
    );
  }

  return <>{children}</>;
}
