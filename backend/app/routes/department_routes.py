from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from app.database import get_db
from app.dependencies import require_admin, require_authenticated
from app.models import Department
from app.schemas import DepartmentCreate, DepartmentUpdate

router = APIRouter(prefix="/api/departments")


def _dept_to_response(d: Department) -> dict:
    return {
        "id": d.id,
        "name": d.name,
        "description": d.description,
        "student_count": len(d.students) if d.students else 0,
    }


def _dept_to_detail(d: Department) -> dict:
    return {
        "id": d.id,
        "name": d.name,
        "description": d.description,
        "student_count": len(d.students) if d.students else 0,
        "students": [
            {
                "id": s.id,
                "name": s.name,
                "email": s.email,
                "keycloak_user_id": s.keycloak_user_id,
                "department_id": s.department_id,
                "department_name": d.name,
            }
            for s in (d.students or [])
        ],
    }


@router.get("/", dependencies=[Depends(require_authenticated)])
async def list_departments(
    db: Session = Depends(get_db),
):
    departments = db.query(Department).all()
    return [_dept_to_response(d) for d in departments]


@router.post("/", dependencies=[Depends(require_admin)], status_code=201)
async def create_department(
    data: DepartmentCreate,
    db: Session = Depends(get_db),
):
    department = Department(name=data.name, description=data.description or None)
    db.add(department)
    db.commit()
    db.refresh(department)
    return _dept_to_response(department)


@router.get("/{department_id}", dependencies=[Depends(require_authenticated)])
async def department_detail(
    department_id: int,
    db: Session = Depends(get_db),
):
    department = db.query(Department).filter(Department.id == department_id).first()
    if not department:
        raise HTTPException(status_code=404, detail="Department not found")

    return _dept_to_detail(department)


@router.put("/{department_id}", dependencies=[Depends(require_admin)])
async def update_department(
    department_id: int,
    data: DepartmentUpdate,
    db: Session = Depends(get_db),
):
    department = db.query(Department).filter(Department.id == department_id).first()
    if not department:
        raise HTTPException(status_code=404, detail="Department not found")

    department.name = data.name
    department.description = data.description or None
    db.commit()
    db.refresh(department)
    return _dept_to_response(department)
