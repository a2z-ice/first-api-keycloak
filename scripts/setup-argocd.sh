#!/usr/bin/env bash
# setup-argocd.sh — Install ArgoCD v3.0.x, configure NodePort, install Nginx Ingress,
#                   apply ApplicationSets, and configure CoreDNS for idp.keycloak.com
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARGOCD_VERSION="v3.0.5"
ARGOCD_NAMESPACE="argocd"
ARGOCD_NODEPORT="30080"

echo "==> Setting up ArgoCD (${ARGOCD_VERSION})..."

# ---- Install ArgoCD ----
echo "    Installing ArgoCD namespace and manifests..."
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${ARGOCD_NAMESPACE}" -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "    Waiting for ArgoCD deployments to be ready..."
kubectl wait --namespace "${ARGOCD_NAMESPACE}" \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=argocd-server \
    --timeout=300s

# ---- Expose ArgoCD UI via NodePort ----
echo "    Patching argocd-server service to NodePort ${ARGOCD_NODEPORT}..."
kubectl patch svc argocd-server -n "${ARGOCD_NAMESPACE}" \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":80,\"targetPort\":8080,\"nodePort\":${ARGOCD_NODEPORT},\"name\":\"http\"},{\"port\":443,\"targetPort\":8080,\"nodePort\":30081,\"name\":\"https\"}]}}"

# ---- Install Nginx Ingress Controller ----
echo "    Installing Nginx Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml

echo "    Waiting for Nginx Ingress to be ready..."
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s

# ---- Configure CoreDNS to resolve idp.keycloak.com ----
echo "    Configuring CoreDNS for idp.keycloak.com resolution..."
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "    Node IP: ${NODE_IP}"

kubectl patch configmap coredns -n kube-system --patch "
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        hosts {
           ${NODE_IP} idp.keycloak.com
           fallthrough
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
"

echo "    Restarting CoreDNS..."
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=60s

# ---- Apply ArgoCD ApplicationSets ----
echo "    Applying ArgoCD ApplicationSets..."
kubectl apply -f "${PROJECT_DIR}/gitops/argocd/applicationsets/environments.yaml"
kubectl apply -f "${PROJECT_DIR}/gitops/argocd/applicationsets/pr-preview.yaml"

# ---- Print credentials ----
echo ""
echo "==> ArgoCD setup complete!"
echo "    UI:      http://localhost:${ARGOCD_NODEPORT}"
echo "    Username: admin"
ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "(secret not yet available)")
echo "    Password: ${ARGOCD_PASSWORD}"
echo ""
echo "    CLI login:"
echo "      argocd login localhost:${ARGOCD_NODEPORT} --username admin --password '${ARGOCD_PASSWORD}' --insecure"
echo ""
