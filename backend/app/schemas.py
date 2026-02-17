from typing import Optional

from pydantic import BaseModel


class StudentCreate(BaseModel):
    name: str
    email: str
    keycloak_user_id: Optional[str] = None
    department_id: Optional[int] = None


class StudentUpdate(BaseModel):
    name: str
    email: str
    keycloak_user_id: Optional[str] = None
    department_id: Optional[int] = None


class DepartmentResponse(BaseModel):
    id: int
    name: str
    description: Optional[str] = None
    student_count: int = 0

    model_config = {"from_attributes": True}


class StudentResponse(BaseModel):
    id: int
    name: str
    email: str
    keycloak_user_id: Optional[str] = None
    department_id: Optional[int] = None
    department_name: Optional[str] = None

    model_config = {"from_attributes": True}


class DepartmentCreate(BaseModel):
    name: str
    description: Optional[str] = None


class DepartmentUpdate(BaseModel):
    name: str
    description: Optional[str] = None


class DepartmentDetailResponse(BaseModel):
    id: int
    name: str
    description: Optional[str] = None
    student_count: int = 0
    students: list[StudentResponse] = []

    model_config = {"from_attributes": True}


class UserResponse(BaseModel):
    sub: Optional[str] = None
    email: Optional[str] = None
    name: Optional[str] = None
    preferred_username: Optional[str] = None
    roles: list[str] = []
