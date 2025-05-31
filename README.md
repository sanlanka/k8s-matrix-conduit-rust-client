# Matrix Conduit Development Environment

🚀 **Complete Matrix development setup with Helm-native Conduit deployment + HTTPS access via Nginx reverse proxy**

This repository provides a complete, production-ready Matrix development environment featuring:
- **Helm-native Conduit Matrix Server** with automated user management
- **Nginx Reverse Proxy** with TLS termination for HTTPS access
- **Local TLS certificates** using mkcert for development
- **Rust Matrix SDK Client** with full CLI interface  
- **Environment-specific configurations** (dev, prod)
- **Kubernetes Jobs** for automated user setup
- **Robust service discovery** with proper DNS resolution

Perfect for building Matrix UIs, testing Matrix applications, or learning the Matrix protocol!

## 🏗️ Architecture

```
┌─────────────────┐     HTTPS (8443)      ┌─────────────────┐
│   Your Browser  │ ◄─────────────────────► │ Nginx Proxy Pod │
│  conduit.local  │                        │   (TLS Term)    │
└─────────────────┘                        └─────────────────┘
                                                     │
                                            HTTP (6167)
                                                     ▼
┌─────────────────┐    Kubernetes Pod      ┌─────────────────┐
│  Conduit Server │ ◄─────────────────────► │  RocksDB Store  │
│  (Helm Chart)   │                        │  (Persistent)   │
└─────────────────┘                        └─────────────────┘
        │
        ▼
┌─────────────────┐
│ User Setup Job  │ (Kubernetes Job - Helm Hook)
│ (Post-Install)  │
└─────────────────┘
```

## 🚀 Quick Start

### Prerequisites

**Required:**
- **Kubernetes cluster** (Docker Desktop, minikube, or cloud provider)
- **Helm 3.x** - [Installation Guide](https://helm.sh/docs/intro/install/)
- **kubectl** configured for your cluster
- **mkcert** - For local TLS certificates
  - **macOS:** `brew install mkcert`
  - **Linux:** `apt install mkcert` or download from [releases](https://github.com/FiloSottile/mkcert/releases)
  - **Windows:** `choco install mkcert` or download from releases

**Optional (for Rust client):**
- **Rust & Cargo** - [Install from rustup.rs](https://rustup.rs/)

### 🎯 Complete Setup (Recommended)

The complete setup script handles everything including TLS certificates, deployment, and testing:

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Complete setup with TLS certificates + Helm deployment + Rust client + testing
./scripts/deploy.sh
```

This script will:
1. Check prerequisites
2. Generate local TLS certificates using mkcert
3. Deploy Conduit Matrix server via Helm
4. Set up nginx reverse proxy with HTTPS
5. Create test users automatically
6. Build and test the Rust Matrix SDK client
7. Verify the complete setup works

### 🔧 Manual Setup (Step-by-Step)

If you prefer to understand each step:

#### 1. Setup Local TLS Certificates

```bash
# Install mkcert and setup local CA
mkcert -install

# Generate certificates for conduit.local
./scripts/generate-tls-cert.sh

# Add local domain to hosts file (required for development)
echo "127.0.0.1 conduit.local" | sudo tee -a /etc/hosts
```

#### 2. Deploy Matrix Conduit

```bash
# Development environment (default)
./scripts/helm-deploy.sh --environment dev

# Production environment
./scripts/helm-deploy.sh --environment prod --namespace matrix-prod
```

#### 3. Verify Deployment

```bash
# Check pod status
kubectl get pods -n matrix

# Check services
kubectl get svc -n matrix

# Test HTTPS endpoint
curl -k https://conduit.local:8443

# Test Matrix API
curl -k https://conduit.local:8443/_matrix/client/versions
```

#### 4. Build Rust Client (Optional)

```bash
cd rust-client
cargo build --release

# Test the client
cargo run --bin matrix-client -- --help
```

## 📡 Accessing the Server

After deployment, your Matrix Conduit server will be accessible at:

- **HTTPS Endpoint:** `https://conduit.local:8443`
- **Matrix Client API:** `https://conduit.local:8443/_matrix/client/versions`
- **Homeserver URL:** `https://conduit.local:8443`

**Note:** The LoadBalancer service automatically exposes the server on port 8443. No manual port forwarding required!

## 👥 Test Users

After deployment, these users are automatically created (dev environment):

| Username | Password | Display Name  | Role  |
|----------|----------|---------------|-------|
| `admin`  | `admin123` | Administrator | Admin |
| `bob`    | `bob123`   | Bob Smith     | User  |
| `rachel` | `rachel123` | Rachel Green  | User  |
| `alice`  | `alice123` | Alice Wonder  | User  |
| `charlie`| `charlie123` | Charlie Brown | User  |

**Homeserver URL:** `https://conduit.local:8443`

## 🦀 Rust Matrix SDK Client

### CLI Commands

#### Send a Message
```bash
cargo run --bin matrix-client -- send \
  --homeserver https://conduit.local:8443 \
  --username rachel \
  --password rachel123 \
  --room-id "!roomid:conduit.local" \
  --message "Hello Matrix! 👋"
```

#### Create a Room  
```bash
cargo run --bin matrix-client -- create-room \
  --homeserver https://conduit.local:8443 \
  --username admin \
  --password admin123 \
  --name "My Test Room" \
  --topic "A room for testing"
```

#### List Rooms
```bash
cargo run --bin matrix-client -- list-rooms \
  --homeserver https://conduit.local:8443 \
  --username bob \
  --password bob123
```

## 🌐 Matrix API Examples

### Direct HTTPS API Calls

#### Check Server Status
```bash
curl -k https://conduit.local:8443/_matrix/client/versions
```

#### Register a User
```bash
curl -k -X POST https://conduit.local:8443/_matrix/client/v3/register \
  -H "Content-Type: application/json" \
  -d '{
    "auth": {"type": "m.login.dummy"},
    "username": "testuser",
    "password": "testpass123"
  }'
```

#### Login
```bash
curl -k -X POST https://conduit.local:8443/_matrix/client/v3/login \
  -H "Content-Type: application/json" \
  -d '{
    "type": "m.login.password",
    "user": "admin",
    "password": "admin123"
  }'
```

## 🛠️ Deployment Management

### Environment Configurations

- **Development** (`values-dev.yaml`): Local testing, test users, LoadBalancer service
- **Production** (`values-prod.yaml`): Security hardened, custom domain support
- **Base** (`values.yaml`): Default configuration

### Deployment Commands

```bash
# Check deployment status
helm status conduit -n matrix

# View all resources
kubectl get all -n matrix

# View logs
kubectl logs -f deployment/conduit -n matrix
kubectl logs -f deployment/conduit-nginx -n matrix

# Upgrade deployment
helm upgrade conduit helm/conduit -n matrix -f helm/conduit/values-dev.yaml

# Uninstall completely
helm uninstall conduit -n matrix
```

## 🔧 Configuration Customization

### Server Configuration

Edit `helm/conduit/values-dev.yaml` or `values-prod.yaml`:

```yaml
config:
  server_name: "conduit.local"  # Change for production
  allow_registration: true      # Disable for production
  max_request_size: 50971520

# Custom domain and TLS
nginx:
  serverName: "your-domain.com"  # Change for production
  tls:
    secretName: "your-tls-secret"
```

### Add More Test Users

```yaml
userSetup:
  enabled: true
  users:
    - username: "myuser"
      password: "secure-password"
      displayName: "My User"
    - username: "developer"
      password: "dev123"
      displayName: "Developer User"
```

## 🐛 Troubleshooting

### Common Issues

#### 1. 504 Gateway Timeout
**Symptoms:** Getting 504 errors when accessing `https://conduit.local:8443`

**Solution:** This was a common issue we solved. Check that:
```bash
# Verify nginx is using correct service discovery
kubectl logs deployment/conduit-nginx -n matrix

# Check service endpoints
kubectl get endpoints -n matrix

# Restart nginx if needed
kubectl delete pod -l app.kubernetes.io/component=nginx-proxy -n matrix
```

#### 2. DNS Resolution Issues
**Symptoms:** Nginx can't reach the Conduit service

**Root Cause:** The nginx configuration uses fully qualified domain names for robust service discovery:
- ✅ **Correct:** `http://conduit.matrix.svc.cluster.local:6167`
- ❌ **Wrong:** `http://conduit:6167` (can fail in some k8s setups)

#### 3. TLS Certificate Issues
**Symptoms:** Browser security warnings or certificate errors

**Solution:**
```bash
# Regenerate certificates
./scripts/generate-tls-cert.sh

# Verify secret exists
kubectl get secret conduit-tls -n matrix

# Check certificate details
kubectl get secret conduit-tls -n matrix -o yaml
```

#### 4. LoadBalancer Not Working
**Symptoms:** External IP shows `<pending>` or connection refused

**For Docker Desktop:**
```bash
# Check service status
kubectl get svc conduit-nginx -n matrix

# External IP should show 'localhost'
# If pending, restart Docker Desktop Kubernetes
```

**For minikube:**
```bash
# Enable LoadBalancer support
minikube tunnel

# Or use NodePort instead - edit values-dev.yaml:
# service:
#   type: NodePort
```

#### 5. Port Permission Denied
**Symptoms:** `kubectl port-forward` fails with permission denied on port 443

**Solution:** Use unprivileged ports:
```bash
# Use port 8443 instead of 443 (already configured in LoadBalancer)
kubectl port-forward svc/conduit-nginx 8443:8443 -n matrix

# Access via: https://conduit.local:8443
```

### Debugging Commands

```bash
# Check all resources
kubectl get all -n matrix

# Check pod logs
kubectl logs -f deployment/conduit -n matrix
kubectl logs -f deployment/conduit-nginx -n matrix

# Check service endpoints (should only show conduit server pods)
kubectl get endpoints conduit -n matrix

# Test internal connectivity
kubectl exec deployment/conduit-nginx -n matrix -- curl -v http://conduit.matrix.svc.cluster.local:6167

# Check DNS resolution
kubectl exec deployment/conduit-nginx -n matrix -- nslookup conduit.matrix.svc.cluster.local

# View nginx configuration
kubectl exec deployment/conduit-nginx -n matrix -- cat /etc/nginx/conf.d/default.conf
```

## 🔒 Security Notes

### Development vs Production

**Development (`values-dev.yaml`):**
- ✅ LoadBalancer with localhost access
- ✅ Self-signed certificates via mkcert  
- ✅ Test users with simple passwords
- ✅ Open registration for testing
- ⚠️ **NOT suitable for internet exposure**

**Production (`values-prod.yaml`):**
- 🔒 Custom domain with proper TLS certificates
- 🔒 Strong authentication requirements
- 🔒 Registration disabled by default
- 🔒 Resource limits and security policies
- 🔒 Network policies (add as needed)

### Production Checklist

- [ ] Replace `conduit.local` with your actual domain
- [ ] Use proper TLS certificates (Let's Encrypt, etc.)
- [ ] Change all default passwords
- [ ] Disable registration: `allow_registration: false`
- [ ] Set up resource limits
- [ ] Configure backup for persistent storage
- [ ] Set up monitoring and logging
- [ ] Review and apply security policies

## 📂 Project Structure

```
matrix-conduit-rust-client/
├── helm/conduit/              # Helm chart for Conduit server
│   ├── Chart.yaml
│   ├── values.yaml            # Base configuration
│   ├── values-dev.yaml        # Development environment
│   ├── values-prod.yaml       # Production environment
│   └── templates/             # Kubernetes manifests
│       ├── deployment.yaml    # Conduit server deployment
│       ├── service.yaml       # Conduit service (ClusterIP)
│       ├── configmap.yaml     # Conduit configuration
│       ├── nginx-proxy.yaml   # Nginx reverse proxy with TLS
│       ├── user-setup-job.yaml # Automated user creation
│       └── pvc.yaml           # Persistent storage
├── rust-client/               # Rust Matrix SDK client
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs            # CLI client implementation
│       └── user_setup.rs      # User registration script
├── scripts/
│   ├── deploy.sh             # Complete setup (recommended)
│   ├── helm-deploy.sh        # Pure Helm deployment
│   └── generate-tls-cert.sh  # TLS certificate generation
└── README.md                 # This file
```

## 🚀 Key Features & Fixes

### Robust Service Discovery
- **FQDN Service Names:** Uses `conduit.matrix.svc.cluster.local` for reliable service discovery
- **DNS Resolution:** Proper DNS resolver configuration in nginx
- **Service Selectors:** Precise label selectors to avoid endpoint conflicts

### TLS & Security
- **Local Development:** mkcert for trusted local certificates
- **HTTPS Everywhere:** All communication over TLS
- **LoadBalancer Service:** No manual port forwarding required

### Automated Setup
- **One-Command Deployment:** `./scripts/deploy.sh` handles everything
- **User Creation:** Kubernetes Jobs automatically create test users
- **Configuration Management:** Environment-specific values files

### Production Ready
- **Helm Charts:** Industry-standard Kubernetes deployment
- **Persistent Storage:** RocksDB data survives pod restarts
- **Scaling:** Ready for horizontal scaling and HA deployment

## 📚 Useful Resources

- [Matrix Specification](https://spec.matrix.org/)
- [Conduit Documentation](https://gitlab.com/famedly/conduit)
- [Rust Matrix SDK](https://github.com/matrix-org/matrix-rust-sdk)
- [Helm Documentation](https://helm.sh/docs/)
- [mkcert Documentation](https://github.com/FiloSottile/mkcert)

---

**Ready to build production-grade Matrix applications!** 🚀

This setup provides a solid foundation that scales from local development to production deployment.


