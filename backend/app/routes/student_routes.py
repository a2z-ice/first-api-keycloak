from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from app.database import get_db
from app.dependencies import (
    get_current_user,
    get_user_roles,
    get_student_for_user,
    require_admin,
    require_authenticated,
)
from app.models import Student
from app.schemas import StudentCreate, StudentUpdate

router = APIRouter(prefix="/api/students")


def _student_to_response(s: Student) -> dict:
    return {
        "id": s.id,
        "name": s.name,
        "email": s.email,
        "keycloak_user_id": s.keycloak_user_id,
        "department_id": s.department_id,
        "department_name": s.department.name if s.department else None,
    }


@router.get("/", dependencies=[Depends(require_authenticated)])
async def list_students(
    request: Request,
    db: Session = Depends(get_db),
):
    user = get_current_user(request)
    roles = get_user_roles(request)

    if "admin" in roles or "staff" in roles:
        students = db.query(Student).all()
    elif "student" in roles:
        own = get_student_for_user(request, db)
        students = [own] if own else []
    else:
        students = []

    return [_student_to_response(s) for s in students if s]


@router.post("/", dependencies=[Depends(require_admin)], status_code=201)
async def create_student(
    data: StudentCreate,
    db: Session = Depends(get_db),
):
    student = Student(
        name=data.name,
        email=data.email,
        keycloak_user_id=data.keycloak_user_id or None,
        department_id=data.department_id,
    )
    db.add(student)
    db.commit()
    db.refresh(student)
    return _student_to_response(student)


@router.get("/{student_id}", dependencies=[Depends(require_authenticated)])
async def student_detail(
    student_id: int,
    request: Request,
    db: Session = Depends(get_db),
):
    user = get_current_user(request)
    roles = get_user_roles(request)

    student = db.query(Student).filter(Student.id == student_id).first()
    if not student:
        raise HTTPException(status_code=404, detail="Student not found")

    if "student" in roles and "admin" not in roles and "staff" not in roles:
        if student.keycloak_user_id != user.get("sub"):
            raise HTTPException(status_code=403, detail="Access denied")

    return _student_to_response(student)


@router.put("/{student_id}", dependencies=[Depends(require_admin)])
async def update_student(
    student_id: int,
    data: StudentUpdate,
    db: Session = Depends(get_db),
):
    student = db.query(Student).filter(Student.id == student_id).first()
    if not student:
        raise HTTPException(status_code=404, detail="Student not found")

    student.name = data.name
    student.email = data.email
    student.keycloak_user_id = data.keycloak_user_id or None
    student.department_id = data.department_id
    db.commit()
    db.refresh(student)
    return _student_to_response(student)
