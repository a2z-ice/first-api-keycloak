#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERT_DIR="$SCRIPT_DIR"

echo "==> Generating self-signed TLS certificates..."

# Generate CA key and cert
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 \
  -nodes -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
  -subj "/CN=Keycloak CA" 2>/dev/null

# Generate server key
openssl genrsa -out "$CERT_DIR/tls.key" 4096 2>/dev/null

# Generate CSR with SANs
openssl req -new -key "$CERT_DIR/tls.key" -out "$CERT_DIR/tls.csr" \
  -subj "/CN=idp.keycloak.com" \
  -addext "subjectAltName=DNS:idp.keycloak.com,DNS:*.keycloak.svc.cluster.local,DNS:localhost" \
  2>/dev/null

# Sign server cert with CA
openssl x509 -req -in "$CERT_DIR/tls.csr" \
  -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
  -out "$CERT_DIR/tls.crt" -days 365 -sha256 \
  -extfile <(printf "subjectAltName=DNS:idp.keycloak.com,DNS:*.keycloak.svc.cluster.local,DNS:localhost") \
  2>/dev/null

# Clean up intermediate files
rm -f "$CERT_DIR/tls.csr" "$CERT_DIR/ca.srl"

echo "==> Certificates generated in $CERT_DIR"
echo "    - ca.crt (CA certificate)"
echo "    - tls.crt (server certificate)"
echo "    - tls.key (server private key)"
