"""Redis-backed session middleware for multi-replica deployments."""

import json
import uuid
from typing import Optional

from starlette.datastructures import MutableHeaders
from starlette.requests import HTTPConnection
from starlette.types import ASGIApp, Message, Receive, Scope, Send

import redis.asyncio as aioredis
from itsdangerous import BadSignature, URLSafeSerializer

SESSION_COOKIE = "session"
SESSION_TTL = 14 * 24 * 3600  # 14 days


class RedisSessionMiddleware:
    def __init__(
        self,
        app: ASGIApp,
        secret_key: str,
        redis_url: str = "redis://localhost:6379/0",
        session_cookie: str = SESSION_COOKIE,
        max_age: int = SESSION_TTL,
        https_only: bool = False,
    ):
        self.app = app
        self.signer = URLSafeSerializer(secret_key)
        self.redis_url = redis_url
        self.session_cookie = session_cookie
        self.max_age = max_age
        self.https_only = https_only
        self._redis: Optional[aioredis.Redis] = None

    async def _get_redis(self) -> aioredis.Redis:
        if self._redis is None:
            self._redis = aioredis.from_url(
                self.redis_url, decode_responses=True
            )
        return self._redis

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return

        connection = HTTPConnection(scope)
        session_id = None
        initial_data: dict = {}

        # Read session from cookie + Redis
        cookie_value = connection.cookies.get(self.session_cookie)
        if cookie_value:
            try:
                session_id = self.signer.loads(cookie_value)
                redis = await self._get_redis()
                raw = await redis.get(f"session:{session_id}")
                if raw:
                    initial_data = json.loads(raw)
            except (BadSignature, Exception):
                session_id = None

        # Attach session to scope
        scope["session"] = initial_data

        async def send_wrapper(message: Message):
            if message["type"] == "http.response.start":
                session_data = scope.get("session", {})
                headers = MutableHeaders(scope=message)

                if session_data:
                    # Create new session ID if needed
                    if session_id is None:
                        new_id = str(uuid.uuid4())
                    else:
                        new_id = session_id

                    # Store in Redis
                    try:
                        redis = await self._get_redis()
                        await redis.setex(
                            f"session:{new_id}",
                            self.max_age,
                            json.dumps(session_data),
                        )
                    except Exception:
                        pass  # Graceful degradation

                    # Set cookie
                    signed = self.signer.dumps(new_id)
                    cookie = (
                        f"{self.session_cookie}={signed}; Path=/; "
                        f"HttpOnly; Max-Age={self.max_age}; SameSite=lax"
                    )
                    if self.https_only:
                        cookie += "; Secure"
                    headers.append("set-cookie", cookie)
                elif session_id is not None:
                    # Session was cleared — delete from Redis
                    try:
                        redis = await self._get_redis()
                        await redis.delete(f"session:{session_id}")
                    except Exception:
                        pass
                    # Clear cookie
                    headers.append(
                        "set-cookie",
                        f"{self.session_cookie}=; Path=/; "
                        f"HttpOnly; Max-Age=0; SameSite=lax",
                    )

            await send(message)

        await self.app(scope, receive, send_wrapper)
