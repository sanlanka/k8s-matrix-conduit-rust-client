#!/bin/bash

# Generate TLS certificate for development
set -e

# Create directory for certificates
mkdir -p certs

# Generate private key and certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/tls.key \
  -out certs/tls.crt \
  -subj "/CN=conduit.local" \
  -addext "subjectAltName = DNS:conduit.local,DNS:localhost,IP:127.0.0.1"

# Create Kubernetes secret
kubectl create secret tls conduit-tls \
  --cert=certs/tls.crt \
  --key=certs/tls.key \
  -n matrix \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ TLS certificate generated and secret created" 