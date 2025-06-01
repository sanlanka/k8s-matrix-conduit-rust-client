#!/bin/bash

set -e

echo "🚀 Helm-Native Matrix Conduit Deployment"
echo "========================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="matrix"
RELEASE_NAME="conduit"
ENVIRONMENT="${ENVIRONMENT:-dev}"  # Default to dev, can be overridden
CHART_PATH="helm/conduit"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -e|--environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -r|--release)
      RELEASE_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo "Options:"
      echo "  -e, --environment ENV    Environment (dev|prod) [default: dev]"
      echo "  -n, --namespace NS       Kubernetes namespace [default: matrix]"
      echo "  -r, --release NAME       Helm release name [default: conduit]"
      echo "  --dry-run                Perform a dry run"
      echo "  -h, --help               Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

echo -e "${BLUE}📋 Deployment Configuration:${NC}"
echo "Environment: $ENVIRONMENT"
echo "Namespace: $NAMESPACE"
echo "Release: $RELEASE_NAME"
echo "Chart: $CHART_PATH"
echo

# Check prerequisites
echo -e "${YELLOW}🔍 Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl not found. Please install kubectl.${NC}"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo -e "${RED}❌ Helm not found. Please install Helm 3.x.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}❌ Kubernetes cluster not accessible. Please configure kubectl.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"

# Create namespace if it doesn't exist
echo -e "${YELLOW}🏗️  Setting up namespace...${NC}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Determine values file
VALUES_FILE="$CHART_PATH/values.yaml"
if [[ "$ENVIRONMENT" != "default" ]] && [[ -f "$CHART_PATH/values-$ENVIRONMENT.yaml" ]]; then
    VALUES_FILE="$CHART_PATH/values-$ENVIRONMENT.yaml"
    echo -e "${BLUE}📄 Using environment-specific values: values-$ENVIRONMENT.yaml${NC}"
else
    echo -e "${BLUE}📄 Using default values: values.yaml${NC}"
fi

# Deploy or upgrade with Helm
echo -e "${YELLOW}🚀 Deploying Matrix Conduit with Helm...${NC}"

if helm list -n "$NAMESPACE" | grep -q "^$RELEASE_NAME\s"; then
    echo "Release $RELEASE_NAME exists, upgrading..."
    helm upgrade "$RELEASE_NAME" "$CHART_PATH" \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE" \
        --wait \
        --timeout=10m \
        $DRY_RUN
else
    echo "Installing new release $RELEASE_NAME..."
    helm install "$RELEASE_NAME" "$CHART_PATH" \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE" \
        --wait \
        --timeout=10m \
        --create-namespace \
        $DRY_RUN
fi

if [[ -n "$DRY_RUN" ]]; then
    echo -e "${BLUE}🔍 Dry run completed successfully!${NC}"
    exit 0
fi

echo -e "${GREEN}✅ Helm deployment completed!${NC}"

# Get deployment status
echo -e "${BLUE}📊 Deployment Status:${NC}"
kubectl get pods,svc,pvc -n "$NAMESPACE" -l app.kubernetes.io/name=conduit

# Check for user setup job completion
echo -e "${YELLOW}👥 Checking user setup job...${NC}"
if kubectl get job -n "$NAMESPACE" "$RELEASE_NAME-user-setup" &> /dev/null; then
    kubectl wait --for=condition=complete job/"$RELEASE_NAME-user-setup" -n "$NAMESPACE" --timeout=300s || true
    
    echo -e "${BLUE}📋 User setup job logs:${NC}"
    kubectl logs job/"$RELEASE_NAME-user-setup" -n "$NAMESPACE" || echo "No logs available yet"
fi

# Setup port forwarding for local access (dev environment only)
if [[ "$ENVIRONMENT" == "dev" ]]; then
    echo -e "${YELLOW}🌐 Setting up port forwarding for local access...${NC}"
    
    # Kill any existing port-forward processes
    pkill -f "kubectl.*port-forward.*$RELEASE_NAME.*8448" || pkill -f "kubectl.*port-forward.*$RELEASE_NAME.*8443" || true
    
    # Start port forwarding in background
    kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE_NAME-nginx" 8448:8448 &
    PORT_FORWARD_PID=$!
    
    echo -e "${GREEN}🔗 Port forwarding started (PID: $PORT_FORWARD_PID)${NC}"
    echo -e "${BLUE}📡 Conduit accessible at: https://conduit.local:8448${NC}"
    
    # Wait for port forward to establish
    sleep 5
    
    # Test connectivity
    if curl -k -s https://localhost:8448/_matrix/client/versions &> /dev/null; then
        echo -e "${GREEN}✅ Conduit is responding!${NC}"
    else
        echo -e "${YELLOW}⏳ Conduit is starting up, may take a moment...${NC}"
    fi
fi

# Show useful information
echo
echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo "=================================="

if [[ "$ENVIRONMENT" == "dev" ]]; then
    echo -e "${BLUE}🔗 Development Access:${NC}"
    echo "• Conduit server: https://conduit.local:8448"
    echo "• Stop port forwarding: kill $PORT_FORWARD_PID"
fi

echo -e "${BLUE}📋 Available Test Users:${NC}"
if [[ "$ENVIRONMENT" == "dev" ]]; then
    echo "• admin (admin123) - Administrator"
    echo "• bob (bob123) - Bob Smith"
    echo "• rachel (rachel123) - Rachel Green"
    echo "• alice (alice123) - Alice Wonder"
    echo "• charlie (charlie123) - Charlie Brown"
else
    echo "• User setup disabled in $ENVIRONMENT environment"
fi

echo
echo -e "${BLUE}🛠️  Useful Commands:${NC}"
echo "• Check status: kubectl get all -n $NAMESPACE"
echo "• View logs: kubectl logs -f deployment/$RELEASE_NAME -n $NAMESPACE"
echo "• Helm status: helm status $RELEASE_NAME -n $NAMESPACE"
echo "• Upgrade: helm upgrade $RELEASE_NAME $CHART_PATH -n $NAMESPACE --values $VALUES_FILE"
echo "• Uninstall: helm uninstall $RELEASE_NAME -n $NAMESPACE"

if [[ "$ENVIRONMENT" == "dev" ]]; then
    echo
    echo -e "${YELLOW}🦀 Next: Build and test the Rust client!${NC}"
    echo "cd rust-client && cargo build --release"
fi 