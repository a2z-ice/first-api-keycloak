import json
import base64

from fastapi import APIRouter, Request
from fastapi.responses import RedirectResponse

from app.auth import oauth
from config import settings

router = APIRouter()


def _decode_jwt_payload(token: str) -> dict:
    """Decode JWT payload without verification (claims extraction only)."""
    parts = token.split(".")
    if len(parts) != 3:
        return {}
    payload = parts[1]
    # Add padding
    payload += "=" * (4 - len(payload) % 4)
    try:
        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded)
    except Exception:
        return {}


@router.get("/login")
async def login(request: Request):
    """Initiate OAuth2.1 Authorization Code + PKCE flow."""
    redirect_uri = f"{settings.app_url}/callback"
    return await oauth.keycloak.authorize_redirect(request, redirect_uri)


@router.get("/callback")
async def callback(request: Request):
    """Handle the OAuth2.1 callback from Keycloak."""
    token = await oauth.keycloak.authorize_access_token(request)

    # Extract user info from the ID token
    userinfo = token.get("userinfo", {})

    # Decode the access token JWT to get resource_access (roles)
    access_token = token.get("access_token", "")
    access_claims = _decode_jwt_payload(access_token)

    # Store user info in session
    request.session["user"] = {
        "sub": userinfo.get("sub"),
        "email": userinfo.get("email"),
        "name": userinfo.get("name", userinfo.get("preferred_username", "")),
        "preferred_username": userinfo.get("preferred_username"),
    }

    # Store token with decoded resource_access for role extraction
    request.session["token"] = {
        "access_token": access_token,
        "resource_access": access_claims.get("resource_access", {}),
    }

    return RedirectResponse(url="/", status_code=302)


@router.get("/logout")
async def logout(request: Request):
    """Clear session and redirect to Keycloak logout."""
    logout_url = (
        f"{settings.keycloak_url}/realms/{settings.keycloak_realm}"
        f"/protocol/openid-connect/logout"
        f"?post_logout_redirect_uri={settings.app_url}/login-page"
        f"&client_id={settings.keycloak_client_id}"
    )

    request.session.clear()
    return RedirectResponse(url=logout_url, status_code=302)
