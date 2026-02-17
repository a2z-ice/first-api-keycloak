from fastapi import APIRouter, Depends, HTTPException, Request, Form
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.database import get_db
from app.dependencies import (
    get_current_user,
    get_user_roles,
    get_student_for_user,
    require_admin,
    require_authenticated,
)
from app.models import Student, Department

router = APIRouter(prefix="/students")
templates = Jinja2Templates(directory="templates")


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

    return templates.TemplateResponse(
        "students/list.html",
        {"request": request, "students": students, "user": user, "roles": roles},
    )


@router.get("/new", dependencies=[Depends(require_admin)])
async def new_student_form(
    request: Request,
    db: Session = Depends(get_db),
):
    user = get_current_user(request)
    roles = get_user_roles(request)

    departments = db.query(Department).all()
    return templates.TemplateResponse(
        "students/form.html",
        {
            "request": request,
            "student": None,
            "departments": departments,
            "user": user,
            "roles": roles,
        },
    )


@router.post("/new", dependencies=[Depends(require_admin)])
async def create_student(
    request: Request,
    name: str = Form(...),
    email: str = Form(...),
    keycloak_user_id: str = Form(""),
    department_id: str = Form(""),
    db: Session = Depends(get_db),
):
    dept_id = int(department_id) if department_id else None
    student = Student(
        name=name,
        email=email,
        keycloak_user_id=keycloak_user_id or None,
        department_id=dept_id,
    )
    db.add(student)
    db.commit()
    return RedirectResponse(url="/students/", status_code=302)


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

    # Students can only view their own record
    if "student" in roles and "admin" not in roles and "staff" not in roles:
        if student.keycloak_user_id != user.get("sub"):
            raise HTTPException(status_code=403, detail="Access denied")

    return templates.TemplateResponse(
        "students/detail.html",
        {"request": request, "student": student, "user": user, "roles": roles},
    )


@router.get("/{student_id}/edit", dependencies=[Depends(require_admin)])
async def edit_student_form(
    student_id: int,
    request: Request,
    db: Session = Depends(get_db),
):
    user = get_current_user(request)
    roles = get_user_roles(request)

    student = db.query(Student).filter(Student.id == student_id).first()
    if not student:
        raise HTTPException(status_code=404, detail="Student not found")

    departments = db.query(Department).all()
    return templates.TemplateResponse(
        "students/form.html",
        {
            "request": request,
            "student": student,
            "departments": departments,
            "user": user,
            "roles": roles,
        },
    )


@router.post("/{student_id}/edit", dependencies=[Depends(require_admin)])
async def update_student(
    student_id: int,
    request: Request,
    name: str = Form(...),
    email: str = Form(...),
    keycloak_user_id: str = Form(""),
    department_id: str = Form(""),
    db: Session = Depends(get_db),
):
    student = db.query(Student).filter(Student.id == student_id).first()
    if not student:
        raise HTTPException(status_code=404, detail="Student not found")

    student.name = name
    student.email = email
    student.keycloak_user_id = keycloak_user_id or None
    student.department_id = int(department_id) if department_id else None
    db.commit()
    return RedirectResponse(url=f"/students/{student_id}", status_code=302)
