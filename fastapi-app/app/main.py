from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from config import settings
from app.database import init_db
from app.session import RedisSessionMiddleware
from app.routes import auth_routes, student_routes, department_routes

app = FastAPI(title="Student Management System")

# Redis-backed session middleware for multi-replica support
app.add_middleware(
    RedisSessionMiddleware,
    secret_key=settings.app_secret_key,
    redis_url=settings.redis_url,
)

# Static files
app.mount("/static", StaticFiles(directory="static"), name="static")

# Templates
templates = Jinja2Templates(directory="templates")

# Include routers
app.include_router(auth_routes.router)
app.include_router(student_routes.router)
app.include_router(department_routes.router)


@app.on_event("startup")
async def startup():
    init_db()


@app.get("/")
async def home(request: Request):
    user = request.session.get("user")
    if not user:
        return RedirectResponse(url="/login-page", status_code=302)

    from app.dependencies import get_user_roles

    roles = get_user_roles(request)
    return templates.TemplateResponse(
        "home.html",
        {"request": request, "user": user, "roles": roles},
    )


@app.get("/login-page")
async def login_page(request: Request):
    return templates.TemplateResponse("login.html", {"request": request})
