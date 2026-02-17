"""Playwright E2E test configuration and fixtures."""

import os
import ssl
import sys

import httpx
import pytest

KEYCLOAK_URL = "https://idp.keycloak.com:31111"
REALM = "student-mgmt"
APP_URL = os.environ.get("APP_URL", "http://localhost:8000")

# Keycloak user credentials
USERS = {
    "admin": {"username": "admin-user", "password": "admin123", "role": "admin"},
    "student": {"username": "student-user", "password": "student123", "role": "student"},
    "staff": {"username": "staff-user", "password": "staff123", "role": "staff"},
}

# SSL context for Keycloak self-signed cert
ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE


def _get_admin_token():
    """Get admin access token from Keycloak master realm."""
    with httpx.Client(verify=ssl_ctx) as client:
        resp = client.post(
            f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token",
            data={
                "username": "admin",
                "password": "admin",
                "grant_type": "password",
                "client_id": "admin-cli",
            },
        )
        return resp.json()["access_token"]


def _get_keycloak_user_id(token: str, username: str) -> str:
    """Look up a Keycloak user ID by username."""
    with httpx.Client(verify=ssl_ctx) as client:
        resp = client.get(
            f"{KEYCLOAK_URL}/admin/realms/{REALM}/users",
            params={"username": username, "exact": "true"},
            headers={"Authorization": f"Bearer {token}"},
        )
        users = resp.json()
        return users[0]["id"]


def _setup_test_data():
    """Create student records in the app DB linked to Keycloak users."""
    # Add project root to path so we can import app modules
    sys.path.insert(0, ".")

    from app.database import init_db, SessionLocal
    from app.models import Student, Department

    init_db()
    db = SessionLocal()

    try:
        # Ensure departments exist
        if db.query(Department).count() == 0:
            for dept in [
                {"name": "Computer Science", "description": "CS department"},
                {"name": "Mathematics", "description": "Math department"},
                {"name": "Physics", "description": "Physics department"},
            ]:
                db.add(Department(**dept))
            db.commit()

        cs_dept = db.query(Department).filter(Department.name == "Computer Science").first()

        # Get Keycloak user IDs
        token = _get_admin_token()

        # Create student record for student-user
        student_kc_id = _get_keycloak_user_id(token, "student-user")
        existing = db.query(Student).filter(Student.keycloak_user_id == student_kc_id).first()
        if not existing:
            db.add(Student(
                name="Student User",
                email="student-user@example.com",
                keycloak_user_id=student_kc_id,
                department_id=cs_dept.id if cs_dept else None,
            ))

        # Create another student (not linked to any Keycloak user) for visibility tests
        existing2 = db.query(Student).filter(Student.email == "other-student@example.com").first()
        if not existing2:
            db.add(Student(
                name="Other Student",
                email="other-student@example.com",
                keycloak_user_id=None,
                department_id=cs_dept.id if cs_dept else None,
            ))

        db.commit()
        print("Test data created successfully")
    finally:
        db.close()


# Run setup once at the start of the test session
def pytest_configure(config):
    """Set up test data before any tests run."""
    _setup_test_data()


@pytest.fixture(scope="session")
def browser_context_args(browser_context_args):
    """Configure browser context to ignore HTTPS errors for Keycloak."""
    return {
        **browser_context_args,
        "ignore_https_errors": True,
    }


def _login(page, username: str, password: str):
    """Helper: perform Keycloak login flow."""
    page.goto(f"{APP_URL}/login")

    # Wait for Keycloak login page to load
    page.wait_for_selector("#username", timeout=15000)

    page.fill("#username", username)
    page.fill("#password", password)
    page.click("#kc-login")

    # Wait for redirect back to app
    page.wait_for_url(f"{APP_URL}/**", timeout=15000)


@pytest.fixture()
def admin_page(page):
    """Page logged in as admin-user."""
    _login(page, "admin-user", "admin123")
    return page


@pytest.fixture()
def student_page(page):
    """Page logged in as student-user."""
    _login(page, "student-user", "student123")
    return page


@pytest.fixture()
def staff_page(page):
    """Page logged in as staff-user."""
    _login(page, "staff-user", "staff123")
    return page
