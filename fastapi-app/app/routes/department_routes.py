from fastapi import APIRouter, Depends, HTTPException, Request, Form
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.database import get_db
from app.dependencies import (
    get_current_user,
    get_user_roles,
    require_admin,
    require_authenticated,
)
from app.models import Department

router = APIRouter(prefix="/departments")
templates = Jinja2Templates(directory="templates")


@router.get("/", dependencies=[Depends(require_authenticated)])
async def list_departments(
    request: Request,
    db: Session = Depends(get_db),
):
    user = get_current_user(request)
    roles = get_user_roles(request)
    departments = db.query(Department).all()

    return templates.TemplateResponse(
        "departments/list.html",
        {"request": request, "departments": departments, "user": user, "roles": roles},
    )


@router.get("/new", dependencies=[Depends(require_admin)])
async def new_department_form(
    request: Request,
):
    user = get_current_user(request)
    roles = get_user_roles(request)

    return templates.TemplateResponse(
        "departments/form.html",
        {"request": request, "department": None, "user": user, "roles": roles},
    )


@router.post("/new", dependencies=[Depends(require_admin)])
async def create_department(
    request: Request,
    name: str = Form(...),
    description: str = Form(""),
    db: Session = Depends(get_db),
):
    department = Department(name=name, description=description or None)
    db.add(department)
    db.commit()
    return RedirectResponse(url="/departments/", status_code=302)


@router.get("/{department_id}", dependencies=[Depends(require_authenticated)])
async def department_detail(
    department_id: int,
    request: Request,
    db: Session = Depends(get_db),
):
    user = get_current_user(request)
    roles = get_user_roles(request)

    department = (
        db.query(Department).filter(Department.id == department_id).first()
    )
    if not department:
        raise HTTPException(status_code=404, detail="Department not found")

    return templates.TemplateResponse(
        "departments/detail.html",
        {"request": request, "department": department, "user": user, "roles": roles},
    )


@router.get("/{department_id}/edit", dependencies=[Depends(require_admin)])
async def edit_department_form(
    department_id: int,
    request: Request,
    db: Session = Depends(get_db),
):
    user = get_current_user(request)
    roles = get_user_roles(request)

    department = (
        db.query(Department).filter(Department.id == department_id).first()
    )
    if not department:
        raise HTTPException(status_code=404, detail="Department not found")

    return templates.TemplateResponse(
        "departments/form.html",
        {"request": request, "department": department, "user": user, "roles": roles},
    )


@router.post("/{department_id}/edit", dependencies=[Depends(require_admin)])
async def update_department(
    department_id: int,
    request: Request,
    name: str = Form(...),
    description: str = Form(""),
    db: Session = Depends(get_db),
):
    department = (
        db.query(Department).filter(Department.id == department_id).first()
    )
    if not department:
        raise HTTPException(status_code=404, detail="Department not found")

    department.name = name
    department.description = description or None
    db.commit()
    return RedirectResponse(url=f"/departments/{department_id}", status_code=302)
