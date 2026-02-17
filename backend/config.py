from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    keycloak_url: str = "https://idp.keycloak.com:31111"
    keycloak_realm: str = "student-mgmt"
    keycloak_client_id: str = "student-app"
    keycloak_client_secret: str = "student-app-secret"
    app_secret_key: str = "super-secret-key"
    app_url: str = "http://localhost:8000"
    frontend_url: str = "http://localhost:5173"
    database_url: str = "sqlite:///./students.db"
    redis_url: str = "redis://localhost:6379/0"
    keycloak_ca_cert: str = "../certs/ca.crt"

    @property
    def keycloak_openid_config_url(self) -> str:
        return (
            f"{self.keycloak_url}/realms/{self.keycloak_realm}"
            f"/.well-known/openid-configuration"
        )

    @property
    def keycloak_issuer(self) -> str:
        return f"{self.keycloak_url}/realms/{self.keycloak_realm}"

    model_config = {"env_file": ".env", "extra": "ignore"}


settings = Settings()
