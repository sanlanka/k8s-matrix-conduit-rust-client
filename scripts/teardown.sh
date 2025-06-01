#!/bin/bash

# Strict mode
set -euo pipefail

# Default values
NAMESPACE="matrix"
RELEASE_NAME="conduit"
DOMAIN="conduit.local"
SKIP_HOSTS=false
FORCE=false

# Help message
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Completely tears down the Matrix Conduit deployment."
  echo ""
  echo "Options:"
  echo "  -n, --namespace NS       Kubernetes namespace (default: matrix)"
  echo "  -r, --release NAME       Helm release name (default: conduit)"
  echo "  -d, --domain DOMAIN      Domain name (default: conduit.local)"
  echo "      --skip-hosts         Skip /etc/hosts cleanup"
  echo "      --force              Skip confirmation prompts"
  echo "  -h, --help               Show this help message"
  exit 0
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift ;;
    -r|--release) RELEASE_NAME="$2"; shift ;;
    -d|--domain) DOMAIN="$2"; shift ;;
    --skip-hosts) SKIP_HOSTS=true ;;
    --force) FORCE=true ;;
    -h|--help) usage ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# Confirmation prompt
if [ "$FORCE" = false ]; then
  read -p "🚨 Are you sure you want to delete namespace '$NAMESPACE', Helm release '$RELEASE_NAME', and related resources? (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Teardown aborted by user."
    exit 0
  fi
fi

echo "🧹 Starting complete teardown..."

# 1. Uninstall Helm release
echo "🗑️ Uninstalling Helm release '$RELEASE_NAME' from namespace '$NAMESPACE'..."
if helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
  echo "✅ Helm release '$RELEASE_NAME' uninstalled."
else
  echo "ℹ️ Helm release '$RELEASE_NAME' not found in namespace '$NAMESPACE'. Skipping."
fi

# 2. Find and force-delete any remaining resources (PVCs, secrets, etc.)
echo "🔍 Finding and deleting remaining resources in namespace '$NAMESPACE'..."
# Delete PVCs
PVCs=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')
if [ -n "$PVCs" ]; then
  echo "Deleting PVCs: $PVCs"
  kubectl delete pvc $PVCs -n "$NAMESPACE" --force --grace-period=0
else
  echo "No PVCs found to delete."
fi

# Delete Secrets (specifically conduit-tls and potentially others)
SECRETS=$(kubectl get secret -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME" -o jsonpath='{.items[*].metadata.name}')
if [ -n "$SECRETS" ]; then
  echo "Deleting Secrets: $SECRETS"
  kubectl delete secret $SECRETS -n "$NAMESPACE" --force --grace-period=0
else
  echo "No release-specific secrets found to delete."
fi
# Delete the TLS secret if it exists and wasn't caught by the label
if kubectl get secret conduit-tls -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "Deleting TLS secret 'conduit-tls'..."
    kubectl delete secret conduit-tls -n "$NAMESPACE" --force --grace-period=0
fi


# 3. Delete the entire matrix namespace
echo "🗑️ Deleting namespace '$NAMESPACE'..."
if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
  kubectl delete namespace "$NAMESPACE" --force --grace-period=0
  echo "⏳ Waiting for namespace '$NAMESPACE' to be fully terminated..."
  # Wait for namespace to be deleted. This can take a while.
  timeout=300 # 5 minutes
  start_time=$(date +%s)
  while kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))
    if [ $elapsed_time -ge $timeout ]; then
      echo "⚠️ Timeout waiting for namespace '$NAMESPACE' to delete. Please check manually."
      break
    fi
    echo -n "."
    sleep 5
  done
  echo ""
  if ! kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
    echo "✅ Namespace '$NAMESPACE' deleted."
  fi
else
  echo "ℹ️ Namespace '$NAMESPACE' not found. Skipping."
fi

# 4. Remove local certificate files
echo "🧹 Removing local certificate files for '$DOMAIN'..."
if [ -d "certs" ]; then
  rm -f "certs/$DOMAIN.crt" "certs/$DOMAIN.key"
  # Attempt to remove certs directory if empty
  if [ -z "$(ls -A certs)" ]; then
    rmdir certs
    echo "✅ Removed 'certs' directory (it was empty)."
  else
    echo "ℹ️ 'certs' directory still contains other files."
  fi
  echo "✅ Local certificate files for '$DOMAIN' removed (if they existed)."
else
  echo "ℹ️ 'certs' directory not found. Skipping certificate cleanup."
fi
# Remove other potential cert files in root if any (as per README example)
rm -f "$DOMAIN.pem" "$DOMAIN.key" "$DOMAIN.crt"
echo "✅ Removed root certificate files for '$DOMAIN' (if they existed)."


# 5. Optionally clean up /etc/hosts entry
if [ "$SKIP_HOSTS" = false ]; then
  echo "🏠 Cleaning up /etc/hosts entry for '$DOMAIN'..."
  if grep -q "$DOMAIN" /etc/hosts; then
    echo "🔑 Sudo permission may be required to edit /etc/hosts."
    if sudo sed -i.bak "/$DOMAIN/d" /etc/hosts; then
      echo "✅ Removed '$DOMAIN' from /etc/hosts. Backup created at /etc/hosts.bak."
    else
      echo "⚠️ Failed to remove '$DOMAIN' from /etc/hosts. Please do it manually."
    fi
  else
    echo "ℹ️ '$DOMAIN' not found in /etc/hosts. Skipping."
  fi
else
  echo "⏭️ Skipping /etc/hosts cleanup as requested."
fi

# 6. Verify complete removal
echo "📊 Verifying complete removal..."
helm_release_exists=false
if helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
  helm_release_exists=true
fi

namespace_exists=false
if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
  namespace_exists=true
fi

certs_exist=false
if [ -f "certs/$DOMAIN.crt" ] || [ -f "certs/$DOMAIN.key" ] || [ -f "$DOMAIN.pem" ]; then
  certs_exist=true
fi

hosts_entry_exists=false
if grep -q "$DOMAIN" /etc/hosts; then
  hosts_entry_exists=true
fi

if [ "$helm_release_exists" = true ]; then
  echo "❌ Verification failed: Helm release '$RELEASE_NAME' still exists."
elif [ "$namespace_exists" = true ]; then
  echo "❌ Verification failed: Namespace '$NAMESPACE' still exists."
elif [ "$certs_exist" = true ]; then
  echo "❌ Verification failed: Certificate files for '$DOMAIN' still exist."
elif [ "$SKIP_HOSTS" = false ] && [ "$hosts_entry_exists" = true ]; then
  echo "❌ Verification failed: Hosts entry for '$DOMAIN' still exists in /etc/hosts."
else
  echo "✅🎉 Teardown complete! All specified resources have been removed."
fi

echo "👋 Teardown script finished." 