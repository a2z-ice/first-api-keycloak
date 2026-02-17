#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTER_NAME="keycloak-cluster"

echo "==> Cleaning up..."

# Delete Kind cluster
if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo "    Deleting Kind cluster '${CLUSTER_NAME}'..."
    kind delete cluster --name "$CLUSTER_NAME"
else
    echo "    No Kind cluster '${CLUSTER_NAME}' found."
fi

# Remove generated certificates
echo "    Removing generated certificates..."
rm -f "$PROJECT_DIR/certs/ca.crt" "$PROJECT_DIR/certs/ca.key"
rm -f "$PROJECT_DIR/certs/tls.crt" "$PROJECT_DIR/certs/tls.key"
rm -f "$PROJECT_DIR/certs/tls.csr" "$PROJECT_DIR/certs/ca.srl"

# Remove SQLite database
rm -f "$PROJECT_DIR/fastapi-app/students.db"

# Remove Docker build artifacts
rm -rf "$PROJECT_DIR/fastapi-app/certs"

# Remove Python venv
if [ -d "$PROJECT_DIR/fastapi-app/venv" ]; then
    echo "    Removing Python virtual environment..."
    rm -rf "$PROJECT_DIR/fastapi-app/venv"
fi

echo "==> Cleanup complete!"
