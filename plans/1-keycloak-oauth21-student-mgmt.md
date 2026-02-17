# Plan 1: Keycloak OAuth2.1 + FastAPI Student Management System

> **Plan Name**: keycloak-oauth21-student-mgmt
> **Created**: 2026-02-16
> **Status**: Implemented

---

## Summary

Complete OAuth2.1-secured Student Management System with:
- Keycloak 26.5.3 in Kind cluster (3 replicas, HTTPS, jdbc-ping)
- FastAPI app with OAuth2.1 Authorization Code + PKCE (S256)
- Role-based access (admin, student, staff)
- Two tables: Student, Department
- Seven pages: login, home, student list/detail/form, department list/detail/form

## Key Configuration

| Item | Value |
|------|-------|
| Keycloak URL | https://idp.keycloak.com:31111 |
| Realm | student-mgmt |
| Client ID | student-app |
| Keycloak image | quay.io/keycloak/keycloak:26.5.3 |
| Cache stack | jdbc-ping (default, only non-deprecated stack) |
| Health probes | Port 9000 (management interface) |
| FastAPI URL | http://localhost:8000 |

## Test Users

| Username | Password | Role |
|----------|----------|------|
| admin-user | admin123 | admin |
| student-user | student123 | student |
| staff-user | staff123 | staff |
