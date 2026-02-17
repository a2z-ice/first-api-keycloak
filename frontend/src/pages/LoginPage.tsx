export default function LoginPage() {
  return (
    <div className="login-container">
      <h1>Student Management System</h1>
      <p>OAuth2.1 secured with Keycloak</p>
      <a href="/api/auth/login" className="btn btn-primary btn-lg">
        Login with Keycloak
      </a>
    </div>
  );
}
