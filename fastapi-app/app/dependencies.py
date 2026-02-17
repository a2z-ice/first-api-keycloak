from typing import Optional

from fastapi import Depends, HTTPException, Request
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Student


def get_current_user(request: Request) -> dict:
    """Get the current user from the session."""
    user = request.session.get("user")
    if not user:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return user


def get_user_roles(request: Request) -> list[str]:
    """Extract client roles from the token stored in session."""
    token = request.session.get("token", {})
    resource_access = token.get("resource_access", {})
    client_roles = resource_access.get("student-app", {})
    return client_roles.get("roles", [])


def require_authenticated(request: Request) -> dict:
    """Dependency that ensures the user is authenticated. Returns the user dict."""
    return get_current_user(request)


def require_admin(request: Request) -> dict:
    """Dependency that ensures the user has the admin role."""
    user = get_current_user(request)
    roles = get_user_roles(request)
    if "admin" not in roles:
        raise HTTPException(status_code=403, detail="Admin access required")
    return user


def inject_user_context(request: Request) -> tuple[dict, list[str]]:
    """Returns (user, roles) tuple for template rendering."""
    user = get_current_user(request)
    roles = get_user_roles(request)
    return user, roles


def get_student_for_user(
    request: Request, db: Session = Depends(get_db)
) -> Optional[Student]:
    """Get the student record linked to the current Keycloak user."""
    user = get_current_user(request)
    keycloak_user_id = user.get("sub")
    if not keycloak_user_id:
        return None
    return (
        db.query(Student)
        .filter(Student.keycloak_user_id == keycloak_user_id)
        .first()
    )
