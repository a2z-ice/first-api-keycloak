#!/usr/bin/env bash
# setup-infrastructure.sh — Master script: registry → ArgoCD → Jenkins → Keycloak clients
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo " ArgoCD GitOps Infrastructure Setup"
echo "============================================"
echo ""

# ---- Step 1: Local Docker Registry ----
echo "--- Step 1/4: Local Docker Registry ---"
bash "${SCRIPT_DIR}/setup-registry.sh"

# Connect registry to kind network (may already be done by setup-registry.sh)
if docker network ls --format '{{.Name}}' | grep -q '^kind$'; then
    docker network connect kind registry 2>/dev/null || true
fi

# ---- Step 2: ArgoCD + Nginx Ingress + CoreDNS ----
echo "--- Step 2/4: ArgoCD + Nginx Ingress + CoreDNS ---"
bash "${SCRIPT_DIR}/setup-argocd.sh"

# ---- Step 3: Jenkins ----
echo "--- Step 3/4: Jenkins ---"
bash "${SCRIPT_DIR}/setup-jenkins.sh"

# ---- Step 4: Keycloak env clients ----
echo "--- Step 4/4: Keycloak Environment Clients ---"
bash "${SCRIPT_DIR}/setup-keycloak-envs.sh"

echo "============================================"
echo " Infrastructure Setup Complete!"
echo "============================================"
echo ""
echo " Services:"
echo "   ArgoCD UI:        http://localhost:30080"
echo "   Jenkins UI:       http://localhost:8090"
echo "   Local Registry:   http://localhost:5001/v2/_catalog"
echo "   Dev App:          http://dev.student.local:8080"
echo "   Prod App:         http://prod.student.local:8080"
echo ""
echo " /etc/hosts entries needed:"
echo "   127.0.0.1 idp.keycloak.com"
echo "   127.0.0.1 dev.student.local"
echo "   127.0.0.1 prod.student.local"
echo ""
echo " Verify:"
echo "   curl http://localhost:5001/v2/_catalog"
echo "   argocd app list"
echo ""
