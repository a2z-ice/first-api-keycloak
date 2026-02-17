FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app/ app/
COPY templates/ templates/
COPY static/ static/
COPY config.py .
COPY run.py .

# Copy CA cert for Keycloak TLS trust
COPY certs/ca.crt /usr/local/share/ca-certificates/keycloak-ca.crt

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
