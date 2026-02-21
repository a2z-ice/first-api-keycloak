import json
import base64

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, RedirectResponse

from app.auth import oauth
from config import settings

router = APIRouter(prefix="/api/auth")


def _decode_jwt_payload(token: str) -> dict:
    """Decode JWT payload without verification (claims extraction only)."""
    parts = token.split(".")
    if len(parts) != 3:
        return {}
    payload = parts[1]
    payload += "=" * (4 - len(payload) % 4)
    try:
        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded)
    except Exception:
        return {}


@router.get("/login")
async def login(request: Request):
    """Initiate OAuth2.1 Authorization Code + PKCE flow."""
    redirect_uri = f"{settings.app_url}/api/auth/callback"
    return await oauth.keycloak.authorize_redirect(request, redirect_uri)


@router.get("/callback")
async def callback(request: Request):
    """Handle the OAuth2.1 callback from Keycloak."""
    token = await oauth.keycloak.authorize_access_token(request)

    userinfo = token.get("userinfo", {})

    access_token = token.get("access_token", "")
    access_claims = _decode_jwt_payload(access_token)

    request.session["user"] = {
        "sub": userinfo.get("sub"),
        "email": userinfo.get("email"),
        "name": userinfo.get("name", userinfo.get("preferred_username", "")),
        "preferred_username": userinfo.get("preferred_username"),
    }

    request.session["token"] = {
        "access_token": access_token,
        "refresh_token": token.get("refresh_token", ""),
        "resource_access": access_claims.get("resource_access", {}),
    }

    return RedirectResponse(url=settings.frontend_url, status_code=302)


@router.get("/me")
async def me(request: Request):
    """Return current user info and roles, or 401 if not authenticated."""
    user = request.session.get("user")
    if not user:
        return JSONResponse(status_code=401, content={"detail": "Not authenticated"})

    token = request.session.get("token", {})
    resource_access = token.get("resource_access", {})
    client_roles = resource_access.get("student-app", {})
    roles = client_roles.get("roles", [])

    return {
        "sub": user.get("sub"),
        "email": user.get("email"),
        "name": user.get("name"),
        "preferred_username": user.get("preferred_username"),
        "roles": roles,
    }


@router.post("/logout")
async def logout(request: Request):
    """Backchannel logout: silently terminate Keycloak session, clear local session."""
    token_data = request.session.get("token", {})
    refresh_token = token_data.get("refresh_token", "")

    if refresh_token:
        try:
            async with httpx.AsyncClient(verify=False) as client:
                await client.post(
                    f"{settings.keycloak_url}/realms/{settings.keycloak_realm}"
                    f"/protocol/openid-connect/logout",
                    data={
                        "client_id": settings.keycloak_client_id,
                        "client_secret": settings.keycloak_client_secret,
                        "refresh_token": refresh_token,
                    },
                )
        except Exception:
            pass  # Best-effort — clear session regardless

    request.session.clear()
    return {"redirect": "/"}
