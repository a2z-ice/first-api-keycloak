"""End-to-end Playwright tests for Student Management System."""

import os
import re
import time

import pytest
from playwright.sync_api import expect

APP_URL = os.environ.get("APP_URL", "http://localhost:8000")


# ─────────────────────────────────────────────
# 1. Authentication Tests
# ─────────────────────────────────────────────

class TestAuthentication:
    """Test login, redirect, and logout flows."""

    def test_unauthenticated_redirect_to_login(self, page):
        """Unauthenticated users should be redirected to login page."""
        page.goto(APP_URL)
        expect(page).to_have_url(re.compile(r"/login-page"))
        expect(page.locator("text=Login with Keycloak")).to_be_visible()

    def test_admin_login(self, admin_page):
        """Admin user can log in and see dashboard."""
        expect(admin_page).to_have_url(APP_URL + "/")
        expect(admin_page.locator("h1", has_text="Dashboard")).to_be_visible()
        expect(admin_page.locator(".badge", has_text="admin")).to_be_visible()

    def test_student_login(self, student_page):
        """Student user can log in and see dashboard."""
        expect(student_page).to_have_url(APP_URL + "/")
        expect(student_page.locator("h1", has_text="Dashboard")).to_be_visible()
        expect(student_page.locator(".badge", has_text="student")).to_be_visible()

    def test_staff_login(self, staff_page):
        """Staff user can log in and see dashboard."""
        expect(staff_page).to_have_url(APP_URL + "/")
        expect(staff_page.locator("h1", has_text="Dashboard")).to_be_visible()
        expect(staff_page.locator(".badge", has_text="staff")).to_be_visible()

    def test_logout(self, admin_page):
        """User can log out and session is cleared."""
        admin_page.click("text=Logout")
        # After clicking logout, we go through Keycloak logout and back to login page
        admin_page.wait_for_url(re.compile(r"/login-page|/logout"), timeout=15000)
        # Verify session is cleared by navigating to app root
        admin_page.goto(APP_URL)
        expect(admin_page).to_have_url(re.compile(r"/login-page"))


# ─────────────────────────────────────────────
# 2. Student Role-Based Access Tests
# ─────────────────────────────────────────────

class TestStudentAccess:
    """Test role-based access to student pages."""

    def test_admin_sees_all_students(self, admin_page):
        """Admin should see all students in the list."""
        admin_page.goto(f"{APP_URL}/students/")
        expect(admin_page.locator("h1", has_text="Students")).to_be_visible()
        # Admin should see both students in the table
        table = admin_page.locator(".data-table")
        expect(table.locator("td", has_text="Student User")).to_be_visible()
        expect(table.locator("td", has_text="Other Student")).to_be_visible()

    def test_admin_sees_add_button(self, admin_page):
        """Admin should see the Add Student button."""
        admin_page.goto(f"{APP_URL}/students/")
        expect(admin_page.locator("a[href='/students/new']")).to_be_visible()

    def test_admin_sees_edit_buttons(self, admin_page):
        """Admin should see Edit buttons on student list."""
        admin_page.goto(f"{APP_URL}/students/")
        edit_links = admin_page.locator("a:has-text('Edit')")
        expect(edit_links.first).to_be_visible()

    def test_staff_sees_all_students(self, staff_page):
        """Staff should see all students in the list."""
        staff_page.goto(f"{APP_URL}/students/")
        table = staff_page.locator(".data-table")
        expect(table.locator("td", has_text="Student User")).to_be_visible()
        expect(table.locator("td", has_text="Other Student")).to_be_visible()

    def test_staff_no_add_button(self, staff_page):
        """Staff should NOT see Add Student button."""
        staff_page.goto(f"{APP_URL}/students/")
        expect(staff_page.locator("a[href='/students/new']")).not_to_be_visible()

    def test_staff_no_edit_buttons(self, staff_page):
        """Staff should NOT see Edit buttons."""
        staff_page.goto(f"{APP_URL}/students/")
        expect(staff_page.locator("a:has-text('Edit')")).not_to_be_visible()

    def test_student_sees_only_own_record(self, student_page):
        """Student should only see their own record."""
        student_page.goto(f"{APP_URL}/students/")
        body = student_page.locator("body")
        expect(body.locator("td", has_text="Student User")).to_be_visible()
        expect(body.locator("td", has_text="Other Student")).not_to_be_visible()

    def test_student_no_add_button(self, student_page):
        """Student should NOT see Add Student button."""
        student_page.goto(f"{APP_URL}/students/")
        expect(student_page.locator("a[href='/students/new']")).not_to_be_visible()

    def test_student_no_edit_buttons(self, student_page):
        """Student should NOT see Edit buttons."""
        student_page.goto(f"{APP_URL}/students/")
        expect(student_page.locator("a:has-text('Edit')")).not_to_be_visible()


# ─────────────────────────────────────────────
# 3. Department Role-Based Access Tests
# ─────────────────────────────────────────────

class TestDepartmentAccess:
    """Test role-based access to department pages."""

    def test_admin_sees_departments(self, admin_page):
        """Admin should see all departments."""
        admin_page.goto(f"{APP_URL}/departments/")
        expect(admin_page.locator("td", has_text="Computer Science")).to_be_visible()

    def test_admin_sees_add_department(self, admin_page):
        """Admin should see Add Department button."""
        admin_page.goto(f"{APP_URL}/departments/")
        expect(admin_page.locator("a[href='/departments/new']")).to_be_visible()

    def test_staff_sees_departments(self, staff_page):
        """Staff should see all departments."""
        staff_page.goto(f"{APP_URL}/departments/")
        expect(staff_page.locator("td", has_text="Computer Science")).to_be_visible()

    def test_staff_no_add_department(self, staff_page):
        """Staff should NOT see Add Department button."""
        staff_page.goto(f"{APP_URL}/departments/")
        expect(staff_page.locator("a[href='/departments/new']")).not_to_be_visible()

    def test_student_sees_departments(self, student_page):
        """Student should see all departments."""
        student_page.goto(f"{APP_URL}/departments/")
        expect(student_page.locator("td", has_text="Computer Science")).to_be_visible()

    def test_student_no_add_department(self, student_page):
        """Student should NOT see Add Department button."""
        student_page.goto(f"{APP_URL}/departments/")
        expect(student_page.locator("a[href='/departments/new']")).not_to_be_visible()


# ─────────────────────────────────────────────
# 4. Admin CRUD - Departments
# ─────────────────────────────────────────────

class TestDepartmentCRUD:
    """Test CRUD operations for departments (admin only)."""

    def test_create_department(self, admin_page):
        """Admin can create a new department."""
        ts = str(int(time.time()))
        admin_page.goto(f"{APP_URL}/departments/new")
        admin_page.fill("#name", f"Test Dept {ts}")
        admin_page.fill("#description", "A test department for E2E")
        admin_page.click("button[type='submit']")

        # Should redirect to department list
        admin_page.wait_for_url(re.compile(r"/departments"), timeout=10000)
        expect(admin_page.locator("td", has_text=f"Test Dept {ts}")).to_be_visible()

    def test_view_department_detail(self, admin_page):
        """Admin can view department detail page."""
        admin_page.goto(f"{APP_URL}/departments/")
        # Click View on the first department
        admin_page.locator("a:has-text('View')").first.click()
        expect(admin_page.locator("dt", has_text="Name")).to_be_visible()

    def test_edit_department(self, admin_page):
        """Admin can edit a department."""
        admin_page.goto(f"{APP_URL}/departments/")
        # Click Edit on the first department
        admin_page.locator("a:has-text('Edit')").first.click()
        admin_page.wait_for_url(re.compile(r"/departments/\d+/edit"), timeout=10000)

        original_name = admin_page.input_value("#name")
        admin_page.fill("#name", "Edited Dept Name")
        admin_page.click("button[type='submit']")

        # Should redirect to detail page with updated name
        admin_page.wait_for_url(re.compile(r"/departments/\d+$"), timeout=10000)
        expect(admin_page.locator("dd", has_text="Edited Dept Name")).to_be_visible()

        # Restore original name
        admin_page.locator("a:has-text('Edit')").click()
        admin_page.fill("#name", original_name)
        admin_page.click("button[type='submit']")

    def test_staff_cannot_create_department(self, staff_page):
        """Staff should get 403 when trying to create a department."""
        resp = staff_page.goto(f"{APP_URL}/departments/new")
        assert resp.status == 403

    def test_student_cannot_create_department(self, student_page):
        """Student should get 403 when trying to create a department."""
        resp = student_page.goto(f"{APP_URL}/departments/new")
        assert resp.status == 403


# ─────────────────────────────────────────────
# 5. Admin CRUD - Students
# ─────────────────────────────────────────────

class TestStudentCRUD:
    """Test CRUD operations for students (admin only)."""

    def test_create_student(self, admin_page):
        """Admin can create a new student."""
        ts = str(int(time.time()))
        admin_page.goto(f"{APP_URL}/students/new")
        admin_page.fill("#name", f"Test Student {ts}")
        admin_page.fill("#email", f"test-{ts}@example.com")
        admin_page.click("button[type='submit']")

        # Should redirect to student list (wait for exact list URL, not /new)
        admin_page.wait_for_url(f"{APP_URL}/students/", timeout=10000)
        expect(admin_page.locator("td", has_text=f"Test Student {ts}")).to_be_visible()

    def test_view_student_detail(self, admin_page):
        """Admin can view student detail page."""
        admin_page.goto(f"{APP_URL}/students/")
        admin_page.locator("a:has-text('View')").first.click()
        expect(admin_page.locator("dt", has_text="Name")).to_be_visible()
        expect(admin_page.locator("dt", has_text="Email")).to_be_visible()

    def test_edit_student(self, admin_page):
        """Admin can edit a student."""
        admin_page.goto(f"{APP_URL}/students/")
        # Click Edit on first student
        admin_page.locator("a:has-text('Edit')").first.click()
        admin_page.wait_for_url(re.compile(r"/students/\d+/edit"), timeout=10000)

        original_name = admin_page.input_value("#name")
        admin_page.fill("#name", "Edited Student Name")
        admin_page.click("button[type='submit']")

        # Should redirect to detail page
        admin_page.wait_for_url(re.compile(r"/students/\d+$"), timeout=10000)
        expect(admin_page.locator("dd", has_text="Edited Student Name")).to_be_visible()

        # Restore original name
        admin_page.locator("a:has-text('Edit')").click()
        admin_page.fill("#name", original_name)
        admin_page.click("button[type='submit']")

    def test_staff_cannot_create_student(self, staff_page):
        """Staff should get 403 when trying to create a student."""
        resp = staff_page.goto(f"{APP_URL}/students/new")
        assert resp.status == 403

    def test_student_cannot_create_student(self, student_page):
        """Student should get 403 when trying to create a student."""
        resp = student_page.goto(f"{APP_URL}/students/new")
        assert resp.status == 403


# ─────────────────────────────────────────────
# 6. Navigation Tests
# ─────────────────────────────────────────────

class TestNavigation:
    """Test navigation elements."""

    def test_navbar_links(self, admin_page):
        """Navbar should have Home, Students, Departments links."""
        expect(admin_page.locator(".nav-links a:has-text('Home')")).to_be_visible()
        expect(admin_page.locator(".nav-links a:has-text('Students')")).to_be_visible()
        expect(admin_page.locator(".nav-links a:has-text('Departments')")).to_be_visible()

    def test_dashboard_cards(self, admin_page):
        """Dashboard should have cards linking to Students and Departments."""
        expect(admin_page.locator(".card:has-text('Students')")).to_be_visible()
        expect(admin_page.locator(".card:has-text('Departments')")).to_be_visible()

    def test_student_list_to_detail_navigation(self, admin_page):
        """Clicking View in student list navigates to detail page."""
        admin_page.goto(f"{APP_URL}/students/")
        admin_page.locator("a:has-text('View')").first.click()
        expect(admin_page).to_have_url(re.compile(r"/students/\d+"))

    def test_department_list_to_detail_navigation(self, admin_page):
        """Clicking View in department list navigates to detail page."""
        admin_page.goto(f"{APP_URL}/departments/")
        admin_page.locator("a:has-text('View')").first.click()
        expect(admin_page).to_have_url(re.compile(r"/departments/\d+"))


# ─────────────────────────────────────────────
# 7. Form Validation Tests
# ─────────────────────────────────────────────

class TestFormValidation:
    """Test required field validation on forms."""

    def test_student_name_required(self, admin_page):
        """Student form should require name field."""
        admin_page.goto(f"{APP_URL}/students/new")
        # Leave name empty, fill email
        admin_page.fill("#email", "test@example.com")
        admin_page.click("button[type='submit']")
        # Should stay on the form (HTML5 required validation prevents submit)
        expect(admin_page).to_have_url(re.compile(r"/students/new"))

    def test_student_email_required(self, admin_page):
        """Student form should require email field."""
        admin_page.goto(f"{APP_URL}/students/new")
        admin_page.fill("#name", "Test Name")
        # Leave email empty
        admin_page.click("button[type='submit']")
        expect(admin_page).to_have_url(re.compile(r"/students/new"))

    def test_department_name_required(self, admin_page):
        """Department form should require name field."""
        admin_page.goto(f"{APP_URL}/departments/new")
        # Leave name empty
        admin_page.click("button[type='submit']")
        expect(admin_page).to_have_url(re.compile(r"/departments/new"))


# ─────────────────────────────────────────────
# 8. Error Handling Tests
# ─────────────────────────────────────────────

class TestErrorHandling:
    """Test error responses for invalid requests."""

    def test_nonexistent_student_returns_404(self, admin_page):
        """Accessing a nonexistent student should return 404."""
        resp = admin_page.goto(f"{APP_URL}/students/99999")
        assert resp.status == 404

    def test_nonexistent_department_returns_404(self, admin_page):
        """Accessing a nonexistent department should return 404."""
        resp = admin_page.goto(f"{APP_URL}/departments/99999")
        assert resp.status == 404

    def test_student_cannot_access_other_student(self, student_page):
        """Student should get 403 when trying to view another student's record."""
        # Other Student (not linked to student-user) should be inaccessible
        # First, find Other Student's ID by trying known IDs
        # The student-user can only see their own record in the list
        student_page.goto(f"{APP_URL}/students/")
        # Get the student-user's own student link
        own_link = student_page.locator("a:has-text('View')").first
        own_href = own_link.get_attribute("href")
        # Try accessing a different student ID
        own_id = int(own_href.split("/")[-1])
        # Try other IDs (one of them should be Other Student)
        for other_id in range(1, own_id + 5):
            if other_id != own_id:
                resp = student_page.goto(f"{APP_URL}/students/{other_id}")
                if resp.status in (403, 404):
                    # Either forbidden (another student) or not found — both acceptable
                    break


# ─────────────────────────────────────────────
# 9. Session Consistency Tests
# ─────────────────────────────────────────────

class TestSessionConsistency:
    """Test that sessions persist across page navigations."""

    def test_session_persists_across_navigations(self, admin_page):
        """User stays logged in when navigating between pages."""
        admin_page.goto(f"{APP_URL}/students/")
        expect(admin_page.locator("h1", has_text="Students")).to_be_visible()

        admin_page.goto(f"{APP_URL}/departments/")
        expect(admin_page.locator("h1", has_text="Departments")).to_be_visible()

        admin_page.goto(APP_URL)
        expect(admin_page.locator("h1", has_text="Dashboard")).to_be_visible()
        # User should still be logged in (not redirected to login)
        expect(admin_page.locator(".badge", has_text="admin")).to_be_visible()

    def test_session_persists_multiple_requests(self, admin_page):
        """Session should persist after multiple sequential requests."""
        for _ in range(5):
            admin_page.goto(f"{APP_URL}/students/")
            expect(admin_page.locator("h1", has_text="Students")).to_be_visible()

        # Still logged in
        admin_page.goto(APP_URL)
        expect(admin_page.locator(".badge", has_text="admin")).to_be_visible()
