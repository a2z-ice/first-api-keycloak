from fastapi import FastAPI

from config import settings
from app.database import init_db
from app.session import RedisSessionMiddleware
from app.routes import auth_routes, student_routes, department_routes

app = FastAPI(title="Student Management API")

app.add_middleware(
    RedisSessionMiddleware,
    secret_key=settings.app_secret_key,
    redis_url=settings.redis_url,
)

app.include_router(auth_routes.router)
app.include_router(student_routes.router)
app.include_router(department_routes.router)


@app.on_event("startup")
async def startup():
    init_db()


@app.get("/api/health")
async def health():
    return {"status": "ok"}
