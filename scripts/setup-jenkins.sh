#!/usr/bin/env bash
# setup-jenkins.sh — Generate Kind kubeconfig with real node IP and start Jenkins via docker compose
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JENKINS_DIR="${PROJECT_DIR}/jenkins"
KUBECONFIG_FILE="${JENKINS_DIR}/kind-jenkins.config"
CLUSTER_NAME="keycloak-cluster"

echo "==> Setting up Jenkins..."

# ---- Generate kubeconfig with real node IP (not 127.0.0.1) ----
echo "    Generating Kind kubeconfig for Jenkins (using node IP instead of 127.0.0.1)..."

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
API_PORT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|.*:||')

echo "    Kind node IP: ${NODE_IP}, API port: ${API_PORT}"

kind get kubeconfig --name "${CLUSTER_NAME}" | \
    sed "s|server: https://127.0.0.1:${API_PORT}|server: https://${NODE_IP}:6443|g" \
    > "${KUBECONFIG_FILE}"

chmod 600 "${KUBECONFIG_FILE}"
echo "    Kubeconfig written to: ${KUBECONFIG_FILE}"

# ---- Start Jenkins ----
echo "    Starting Jenkins via docker compose..."
cd "${JENKINS_DIR}"
docker compose up -d

echo ""
echo "==> Jenkins setup complete!"
echo "    UI: http://localhost:8090"
echo "    Initial admin password:"
echo "      docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword"
echo ""
echo "    Required credentials to configure in Jenkins:"
echo "      - GITHUB_TOKEN (GitHub personal access token)"
echo "      - ARGOCD_PASSWORD (ArgoCD admin password)"
echo "      - Git SSH key (for pushing overlay commits)"
echo ""
