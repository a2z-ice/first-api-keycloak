#!/usr/bin/env bash
# setup-registry.sh — Start a local Docker registry on the 'kind' network (port 5001)
set -euo pipefail

REGISTRY_NAME="registry"
REGISTRY_PORT="5001"

echo "==> Setting up local Docker registry..."

# Check if registry container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
        echo "    Registry '${REGISTRY_NAME}' is already running on port ${REGISTRY_PORT}."
    else
        echo "    Registry container exists but is stopped. Starting it..."
        docker start "${REGISTRY_NAME}"
    fi
else
    echo "    Creating registry container '${REGISTRY_NAME}' on port ${REGISTRY_PORT}..."
    docker run -d \
        --restart=always \
        --name "${REGISTRY_NAME}" \
        -p "127.0.0.1:${REGISTRY_PORT}:5000" \
        registry:2
fi

# Connect registry to the 'kind' network (idempotent)
if docker network ls --format '{{.Name}}' | grep -q '^kind$'; then
    if ! docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q "${REGISTRY_NAME}"; then
        echo "    Connecting registry to 'kind' network..."
        docker network connect kind "${REGISTRY_NAME}" 2>/dev/null || true
    else
        echo "    Registry already connected to 'kind' network."
    fi
else
    echo "    'kind' network not found yet — registry will be connected when Kind cluster is created."
fi

echo "    Registry available at: http://localhost:${REGISTRY_PORT}"
echo "    Catalog: http://localhost:${REGISTRY_PORT}/v2/_catalog"
echo ""
