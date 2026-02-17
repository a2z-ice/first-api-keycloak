import ssl

from authlib.integrations.starlette_client import OAuth

from config import settings

# Create SSL context that trusts our self-signed CA
ssl_context = ssl.create_default_context()
try:
    ssl_context.load_verify_locations(settings.keycloak_ca_cert)
except Exception:
    # Fall back to no verification if CA cert not found
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

oauth = OAuth()

oauth.register(
    name="keycloak",
    client_id=settings.keycloak_client_id,
    client_secret=settings.keycloak_client_secret,
    server_metadata_url=settings.keycloak_openid_config_url,
    client_kwargs={
        "scope": "openid profile email",
        "code_challenge_method": "S256",
        "verify": ssl_context,
    },
)
