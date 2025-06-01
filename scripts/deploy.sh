#!/bin/bash

# Strict mode
set -euo pipefail

# Default values
ENVIRONMENT="dev"
NAMESPACE="matrix"
RELEASE_NAME="conduit"
DOMAIN="conduit.local"
SKIP_HOSTS=false
SKIP_PREREQS=false
MKCERT_INSTALLED=false

# Help message
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Deploys the Matrix Conduit server with Nginx reverse proxy and TLS."
  echo ""
  echo "Options:"
  echo "  -e, --environment ENV    Environment (dev/prod) [default: dev]"
  echo "  -n, --namespace NS       Kubernetes namespace [default: matrix]"
  echo "  -r, --release NAME       Helm release name [default: conduit]"
  echo "  -d, --domain DOMAIN      Domain name for TLS cert (default: conduit.local)"
  echo "      --skip-hosts         Skip /etc/hosts setup (for $DOMAIN)"
  echo "      --skip-prereqs       Skip prerequisite checks"
  echo "  -h, --help               Show this help message"
  exit 0
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -e|--environment) ENVIRONMENT="$2"; shift ;;
    -n|--namespace) NAMESPACE="$2"; shift ;;
    -r|--release) RELEASE_NAME="$2"; shift ;;
    -d|--domain) DOMAIN="$2"; shift ;;
    --skip-hosts) SKIP_HOSTS=true ;;
    --skip-prereqs) SKIP_PREREQS=true ;;
    -h|--help) usage ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# --- Helper Functions ---
check_command() {
  if ! command -v "$1" &> /dev/null; then
    echo "❌ Error: Required command '$1' not found."
    if [ "$1" = "mkcert" ]; then
        echo "Please install mkcert: https://github.com/FiloSottile/mkcert#installation"
    elif [ "$1" = "helm" ]; then
        echo "Please install Helm: https://helm.sh/docs/intro/install/"
    elif [ "$1" = "kubectl" ]; then
        echo "Please install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
    elif [ "$1" = "openssl" ] && [ "$MKCERT_INSTALLED" = false ]; then
        echo "Neither mkcert (preferred) nor openssl found for certificate generation."
    fi
    return 1
  fi
  echo "✅ $1 is available."
  return 0
}

wait_for_pods() {
  local ns="$1"
  local release="$2"
  local timeout_seconds="${3:-300}" # Default 5 minutes
  echo "⏳ Waiting for all pods in namespace '$ns' for release '$release' to be ready..."

  # Wait for Deployments
  local deployments
  deployments=$(kubectl get deployments -n "$ns" -l "app.kubernetes.io/instance=$release" -o jsonpath='{.items[*].metadata.name}')
  if [ -n "$deployments" ]; then
    for deploy in $deployments; do
      echo "Waiting for deployment '$deploy' to be ready..."
      if ! kubectl wait --for=condition=available --timeout="${timeout_seconds}s" "deployment/$deploy" -n "$ns"; then
        echo "❌ Timeout waiting for deployment '$deploy' to become available."
        kubectl logs "deployment/$deploy" -n "$ns" --tail=50 || true
        return 1
      fi
    done
  else
    echo "No deployments found for release '$release' in namespace '$ns'."
  fi
  echo "✅ All deployments are ready."
}

wait_for_job() {
  local ns="$1"
  local job_name_prefix="$2" # e.g., conduit-user-setup
  local timeout_seconds="${3:-180}" # Default 3 minutes
  echo "⏳ Waiting for job matching '$job_name_prefix' in namespace '$ns' to complete..."

  local job_name
  # Try to find the job name (it might have a unique suffix from Helm)
  # We look for a job that has our release label and a name exactly matching the prefix
  job_name=$(kubectl get jobs -n "$ns" -l "app.kubernetes.io/instance=$RELEASE_NAME" -o jsonpath="{.items[?(@.metadata.name=='$job_name_prefix')].metadata.name}" | awk '{print $1}')

  if [ -z "$job_name" ]; then
    echo "Could not find job with prefix '$job_name_prefix' for release '$RELEASE_NAME'. Waiting a bit in case it's still being created."
    sleep 10 # Wait a bit in case the job isn't created immediately
    job_name=$(kubectl get jobs -n "$ns" -l "app.kubernetes.io/instance=$RELEASE_NAME" -o jsonpath="{.items[?(@.metadata.name=='$job_name_prefix')].metadata.name}" | awk '{print $1}')
    if [ -z "$job_name" ]; then
      echo "❌ Job matching '$job_name_prefix' not found after waiting."
      return 1 # Or handle as a non-critical failure if appropriate
    fi
  fi
  echo "Found job: $job_name"

  if kubectl wait --for=condition=complete --timeout="${timeout_seconds}s" "job/$job_name" -n "$ns"; then
    echo "✅ Job '$job_name' completed successfully."
    echo "Job logs:"
    kubectl logs "job/$job_name" -n "$ns" --tail=20 || true
  else
    echo "❌ Timeout or failure waiting for job '$job_name' to complete."
    echo "Job logs (if available):"
    kubectl logs "job/$job_name" -n "$ns" --tail=50 || true
    return 1
  fi
}

# --- Main Script ---

echo "🚀 Starting Matrix Conduit Deployment..."
echo "Environment: $ENVIRONMENT"
echo "Namespace:   $NAMESPACE"
echo "Release:     $RELEASE_NAME"
echo "Domain:      $DOMAIN"

# 1. ✅ Check prerequisites
if [ "$SKIP_PREREQS" = false ]; then
  echo ""
  echo "--- 1. Checking Prerequisites ---"
  check_command kubectl || exit 1
  check_command helm || exit 1
  if check_command mkcert; then
    MKCERT_INSTALLED=true
  elif check_command openssl; then
    echo "ℹ️ mkcert not found, will fall back to OpenSSL if needed by generate-tls-cert.sh (mkcert is recommended)."
  else
    echo "❌ Neither mkcert nor openssl found. One is required for TLS certificate generation."
    exit 1
  fi
else
  echo "⏭️ Skipping prerequisite checks."
fi

# 2. 🏗️ Create the matrix namespace
echo ""
echo "--- 2. Ensuring Namespace '$NAMESPACE' Exists ---"
if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
  echo "✅ Namespace '$NAMESPACE' already exists."
else
  kubectl create namespace "$NAMESPACE"
  echo "✅ Namespace '$NAMESPACE' created."
fi

# 3. 🌐 Add conduit.local to /etc/hosts (dev environment)
if [ "$ENVIRONMENT" = "dev" ] && [ "$SKIP_HOSTS" = false ]; then
  echo ""
  echo "--- 3. Adding '$DOMAIN' to /etc/hosts ---"
  if grep -q "127.0.0.1 $DOMAIN" /etc/hosts; then
    echo "✅ '$DOMAIN' already in /etc/hosts."
  else
    echo "🔑 Sudo permission may be required to edit /etc/hosts."
    if echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts > /dev/null; then
      echo "✅ Added '$DOMAIN' to /etc/hosts."
    else
      echo "⚠️ Failed to add '$DOMAIN' to /etc/hosts. Manual addition might be required."
      echo "Please add the following line to your /etc/hosts file:"
      echo "127.0.0.1 $DOMAIN"
    fi
  fi
elif [ "$SKIP_HOSTS" = true ]; then
  echo "⏭️ Skipping /etc/hosts setup."
else
  echo "ℹ️ Not adding '$DOMAIN' to /etc/hosts (not in 'dev' environment)."
fi

# 4. 🔐 Generate local TLS certificates
echo ""
echo "--- 4. Generating Local TLS Certificates for '$DOMAIN' ---"
# Assuming generate-tls-cert.sh is in the same directory as this script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
if [ -f "$SCRIPT_DIR/generate-tls-cert.sh" ]; then
  # Pass the domain to the certificate generation script
  # And tell it to place certs in a way the Helm chart expects (e.g., ./certs/ directory)
  if "$SCRIPT_DIR/generate-tls-cert.sh" "$DOMAIN"; then
    echo "✅ TLS certificates generated successfully."
  else
    echo "❌ Failed to generate TLS certificates. Check output from generate-tls-cert.sh."
    exit 1
  fi
else
  echo "❌ Script 'generate-tls-cert.sh' not found in '$SCRIPT_DIR'."
  echo "Please ensure it exists and is executable."
  exit 1
fi

# 5. 🚀 Deploy Conduit Matrix server via Helm
echo ""
echo "--- 5. Deploying Conduit Helm Chart '$RELEASE_NAME' ---"
# Assuming helm-deploy.sh is in the same directory
if [ -f "$SCRIPT_DIR/helm-deploy.sh" ]; then
  # Pass relevant arguments to helm-deploy.sh
  # The helm-deploy.sh should handle values files based on environment
  if "$SCRIPT_DIR/helm-deploy.sh" --release "$RELEASE_NAME" --namespace "$NAMESPACE" --environment "$ENVIRONMENT"; then
    echo "✅ Helm deployment initiated."
  else
    echo "❌ Helm deployment failed. Check output from helm-deploy.sh."
    exit 1
  fi
else
  echo "❌ Script 'helm-deploy.sh' not found in '$SCRIPT_DIR'."
  echo "Please ensure it exists and is executable."
  exit 1
fi

# 6. ⏳ Wait for pods to be ready
echo ""
echo "--- 6. Waiting for Pods to be Ready ---"
# We need to identify the correct pods, typically app.kubernetes.io/instance=$RELEASE_NAME
if ! wait_for_pods "$NAMESPACE" "$RELEASE_NAME" 300; then # 5 min timeout
    echo "❌ Some pods did not become ready. Please check:"
    kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME"
    exit 1
fi
echo "✅ All main pods are ready."

# 7. 👥 Wait for user setup job completion
# The user setup job is part of the helm chart, its name might be `conduit-user-setup` or similar
# and include the release name.
# Check if user setup is enabled for the environment (e.g. dev)
USER_SETUP_ENABLED=$(helm get values "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq -r .userSetup.enabled)

if [ "$USER_SETUP_ENABLED" = "true" ]; then
  echo ""
  echo "--- 7. Waiting for User Setup Job Completion ---"
  # The job name in the Helm chart template is often `{{ .Release.Name }}-user-setup` or similar
  # We'll construct a prefix based on that.
  USER_SETUP_JOB_PREFIX="${RELEASE_NAME}-user-setup"
  if ! wait_for_job "$NAMESPACE" "$USER_SETUP_JOB_PREFIX" 180; then # 3 min timeout
      echo "⚠️ User setup job did not complete successfully. Test users might not be available."
      echo "Check job status: kubectl get jobs -n "$NAMESPACE" -l app.kubernetes.io/instance=$RELEASE_NAME"
      echo "Check job logs: kubectl logs -n "$NAMESPACE" -l job-name=${USER_SETUP_JOB_PREFIX} (approximate)"
      # Decide if this is a fatal error or a warning
      # For now, let's issue a warning and continue
  else
    echo "✅ User setup job completed."
  fi
else
  echo "ℹ️ User setup job is disabled for release '$RELEASE_NAME' in namespace '$NAMESPACE'. Skipping wait."
fi


# 8. 🧪 Test the Matrix API endpoint
echo ""
echo "--- 8. Testing Matrix API Endpoint ---"
# Use localhost if skip-hosts is enabled, otherwise use the domain
if [ "$SKIP_HOSTS" = true ]; then
  API_URL="https://localhost:8448/_matrix/client/versions"
else
  API_URL="https://$DOMAIN:8448/_matrix/client/versions"
fi
echo "Pinging API: $API_URL"
# Use --insecure or -k because of self-signed certs
if curl -s -k --connect-timeout 10 --max-time 20 "$API_URL" | grep -q "versions"; then
  echo "✅ Matrix API endpoint is responding correctly."
else
  echo "❌ Failed to connect to Matrix API at $API_URL."
  echo "   Check Nginx proxy logs: kubectl logs -l app.kubernetes.io/component=nginx-proxy,app.kubernetes.io/instance=$RELEASE_NAME -n $NAMESPACE --tail 50"
  echo "   Check Conduit server logs: kubectl logs -l app.kubernetes.io/component=conduit-server,app.kubernetes.io/instance=$RELEASE_NAME -n $NAMESPACE --tail 50"
  echo "   Ensure '$DOMAIN' resolves to your Kubernetes LoadBalancer IP (usually 127.0.0.1 for local dev)."
  # exit 1 # Optionally make this a fatal error
fi

# 9. 🔐 Test user login (if users are created and in dev environment)
if [ "$ENVIRONMENT" = "dev" ] && [ "$USER_SETUP_ENABLED" = "true" ]; then
  echo ""
  echo "--- 9. Testing User Login (admin@$DOMAIN) ---"
  # Use localhost if skip-hosts is enabled
  if [ "$SKIP_HOSTS" = true ]; then
    LOGIN_URL="https://localhost:8448/_matrix/client/v3/login"
  else
    LOGIN_URL="https://$DOMAIN:8448/_matrix/client/v3/login"
  fi
  # Using admin user/pass from typical dev values
  ADMIN_USER="admin"
  ADMIN_PASS="admin123" # This should ideally come from values or be known

  echo "Attempting login for '$ADMIN_USER'..."
  RESPONSE_CODE=$(curl -s -k -X POST -H "Content-Type: application/json" \
    -d "{\"type\": \"m.login.password\", \"identifier\": {\"type\": \"m.id.user\", \"user\": \"$ADMIN_USER\"}, \"password\": \"$ADMIN_PASS\"}" \
    -o /dev/null -w "%{http_code}" \
    "$LOGIN_URL")

  if [ "$RESPONSE_CODE" = "200" ]; then
    echo "✅ Admin user login successful (HTTP $RESPONSE_CODE)."
  else
    echo "❌ Admin user login failed (HTTP $RESPONSE_CODE)."
    echo "   Ensure the user '$ADMIN_USER' with password '$ADMIN_PASS' was created by the user-setup job."
    echo "   Check user-setup job logs: kubectl logs -l job-name=${USER_SETUP_JOB_PREFIX} -n $NAMESPACE --tail 50 (approximate)"
  fi
fi

# 10. 📊 Show deployment status and useful commands
echo ""
echo "--- 10. Deployment Status & Useful Commands ---"
echo "✅ Matrix Conduit deployment process finished for '$RELEASE_NAME' in '$NAMESPACE'."
echo ""
echo "Основные точки доступа:"
if [ "$SKIP_HOSTS" = true ]; then
  echo "  🏠 Homeserver URL: https://localhost:8448"
  echo "  📄 Matrix API:     https://localhost:8448/_matrix/client/versions"
  echo "  ℹ️  Note: Add '127.0.0.1 $DOMAIN' to /etc/hosts to use https://$DOMAIN:8448"
else
  echo "  🏠 Homeserver URL: https://$DOMAIN:8448"
  echo "  📄 Matrix API:     https://$DOMAIN:8448/_matrix/client/versions"
fi
echo ""
echo "Статус развертывания:"
echo "  kubectl get all -n "$NAMESPACE" -l \"app.kubernetes.io/instance=$RELEASE_NAME\""
echo "  helm status "$RELEASE_NAME" -n "$NAMESPACE""
echo ""
echo "Логи:"
echo "  Conduit Server: kubectl logs -f deployment/"$RELEASE_NAME" -n "$NAMESPACE" -c conduit"
echo "  Nginx Proxy:    kubectl logs -f deployment/"$RELEASE_NAME-nginx" -n "$NAMESPACE""
if [ "$USER_SETUP_ENABLED" = "true" ]; then
  # Try to get the exact job name again for logs command
  USER_SETUP_JOB_NAME=$(kubectl get jobs -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/component=user-setup" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || USER_SETUP_JOB_NAME="${USER_SETUP_JOB_PREFIX}-XXXX"
  echo "  User Setup Job: kubectl logs job/$USER_SETUP_JOB_NAME -n "$NAMESPACE""
fi
echo ""
echo "Port forwarding (if LoadBalancer doesn't work):"
echo "  kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE_NAME-nginx" 8448:8448"
echo ""
echo "Для очистки (полное удаление):"
echo "  ./scripts/teardown.sh --namespace "$NAMESPACE" --release "$RELEASE_NAME" --domain "$DOMAIN" ${SKIP_HOSTS:+--skip-hosts} --force"
echo ""
echo "�� Happy Matrixing!"

exit 0 