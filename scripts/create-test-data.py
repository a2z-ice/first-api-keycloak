#!/usr/bin/env python3
"""Seed the database with departments and student records linked to Keycloak users."""

import os
import ssl
import sys

import httpx

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

from app.database import init_db, SessionLocal
from app.models import Department, Student

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "https://idp.keycloak.com:31111")
REALM = os.environ.get("KEYCLOAK_REALM", "student-mgmt")

DEPARTMENTS = [
    {"name": "Computer Science", "description": "Study of computation and information processing"},
    {"name": "Mathematics", "description": "Study of numbers, quantities, and shapes"},
    {"name": "Physics", "description": "Study of matter, energy, and their interactions"},
    {"name": "Engineering", "description": "Application of science to design and build systems"},
    {"name": "Biology", "description": "Study of living organisms"},
]

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
        resp.raise_for_status()
        return resp.json()["access_token"]


def _get_keycloak_user_id(token: str, username: str) -> str:
    """Look up a Keycloak user ID by username."""
    with httpx.Client(verify=ssl_ctx) as client:
        resp = client.get(
            f"{KEYCLOAK_URL}/admin/realms/{REALM}/users",
            params={"username": username, "exact": "true"},
            headers={"Authorization": f"Bearer {token}"},
        )
        resp.raise_for_status()
        users = resp.json()
        if not users:
            raise ValueError(f"User '{username}' not found in Keycloak")
        return users[0]["id"]


def seed():
    init_db()
    db = SessionLocal()
    try:
        # Seed departments (idempotent)
        for dept_data in DEPARTMENTS:
            existing = db.query(Department).filter(
                Department.name == dept_data["name"]
            ).first()
            if not existing:
                db.add(Department(**dept_data))
                print(f"  Created department: {dept_data['name']}")
            else:
                print(f"  Department already exists: {dept_data['name']}")
        db.commit()

        # Get Keycloak user IDs and create linked student records
        try:
            token = _get_admin_token()

            cs_dept = db.query(Department).filter(
                Department.name == "Computer Science"
            ).first()
            dept_id = cs_dept.id if cs_dept else None

            # Student-user record
            student_kc_id = _get_keycloak_user_id(token, "student-user")
            existing = db.query(Student).filter(
                Student.keycloak_user_id == student_kc_id
            ).first()
            if not existing:
                db.add(Student(
                    name="Student User",
                    email="student-user@example.com",
                    keycloak_user_id=student_kc_id,
                    department_id=dept_id,
                ))
                print(f"  Created student: Student User (linked to Keycloak)")
            else:
                print(f"  Student already exists: Student User")

            # Other student (not linked)
            existing2 = db.query(Student).filter(
                Student.email == "other-student@example.com"
            ).first()
            if not existing2:
                db.add(Student(
                    name="Other Student",
                    email="other-student@example.com",
                    keycloak_user_id=None,
                    department_id=dept_id,
                ))
                print(f"  Created student: Other Student")
            else:
                print(f"  Student already exists: Other Student")

            db.commit()
        except Exception as e:
            print(f"  Warning: Could not link Keycloak users: {e}")
            print(f"  Departments were seeded successfully.")

        print("Seed complete.")
    finally:
        db.close()


if __name__ == "__main__":
    seed()
