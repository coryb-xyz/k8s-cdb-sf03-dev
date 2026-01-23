# k8s-cdb-sf03-dev

A GitOps-managed Kubernetes cluster demonstrating modern cloud-native patterns with Flux CD, Gateway API, and automated certificate management.

## Overview

This repository manages a production Kubernetes cluster using **GitOps principles** with Flux CD as the continuous delivery operator. It showcases:

- **Flux CD** for automated Git-to-cluster synchronization
- **Gateway API** for modern ingress routing (replacing legacy Ingress)
- **cert-manager** with Let's Encrypt for automated TLS certificate management
- **Kustomize** base/overlay pattern for environment-specific configurations
- **Image automation** for automatic deployment of new container versions
- **Traefik** as the Gateway controller

## Architecture

### Repository Structure

```
k8s-cdb-sf03-dev/
├── flux-system/               # Flux CD bootstrap & configuration
│   ├── gotk-components.yaml   # Flux CD controllers
│   ├── gotk-sync.yaml         # Git repository sync
│   ├── infrastructure-sync.yaml  # Infrastructure Kustomization
│   ├── applications-sync.yaml    # Applications Kustomization
│   ├── metrics-server.yaml
│   ├── prod-issuer.yaml       # ClusterIssuer for ACME
│   └── kustomization.yaml
├── infrastructure/            # Infrastructure components
│   ├── base/
│   │   ├── cert-manager/      # TLS certificate automation
│   │   ├── traefik/           # Gateway controller
│   │   ├── image-repos/       # Container image scanning
│   │   ├── system-optimizations/  # Resource tuning
│   │   └── kustomization.yaml
│   └── overlays/
│       └── prod/              # Production infra overrides (future)
├── applications/              # Application workloads
│   ├── base/
│   │   └── vanitydomain/      # Application base manifests
│   └── overlays/
│       └── prod/
│           └── vanitydomain/  # Production-specific configs
└── readme.md
```

### GitOps Workflow

```
Developer pushes code
        ↓
Container image built (CI/CD)
        ↓
Image pushed to DigitalOcean registry
        ↓
Flux CD ImageRepository scans for new tags
        ↓
ImageUpdateAutomation updates Git manifest
        ↓
Flux CD Kustomization detects change
        ↓
Deployment updated in cluster
```

### Sync Strategy

Flux CD manages three primary Kustomizations:

1. **Flux System** (`flux-system`): Bootstraps Flux CD and deploys sync configurations
   - Path: `./flux-system`
   - Includes: Flux controllers, GitRepository, infrastructure/app sync configs

2. **Infrastructure** (`infrastructure`): Deploys core cluster services
   - Path: `./infrastructure/base`
   - Includes: cert-manager, Traefik, image-repos, system optimizations

3. **Applications** (`applications`): Deploys workloads with environment variables
   - Path: `./applications/overlays/prod`
   - Variables: `release_env=prod`, `base_uri=coryb.xyz`
   - Health checks: Monitors vanitydomain Deployment

### Certificate Management Flow

```
Let's Encrypt ACME
        ↓
ClusterIssuer (letsencrypt-prod)
        ↓
Certificate CR (vanitydomain-tls-cert)
        ↓
Secret (vanitydomain-tls)
        ↓
Gateway Listener (websecure)
        ↓
HTTPRoute → Backend Service
```

**ACME HTTP-01 Challenge**: Special HTTPRoute handles `/.well-known/acme-challenge/` without HTTPS redirect.

### Variable Substitution

Flux CD's `postBuild.substitute` mechanism enables environment-specific values:

**Configuration** (in [flux-system/applications-sync.yaml](flux-system/applications-sync.yaml)):
```yaml
postBuild:
  substitute:
    release_env: prod        # Used for namespace: prod-vanitydomain
    base_uri: coryb.xyz      # Used for hostnames and DNS SANs
```

**Usage** (in application manifests):
```yaml
# Namespace substitution
namespace: ${release_env}-vanitydomain  # → prod-vanitydomain

# DNS/hostname substitution
spec:
  dnsNames:
    - ${base_uri}                       # → coryb.xyz
    - www.${base_uri}                   # → www.coryb.xyz
```

This pattern allows the same base manifests to deploy across multiple environments (prod, staging, dev) with environment-specific values.

## Prerequisites

- **Flux CLI**: `brew install fluxcd/tap/flux` or see [Flux installation](https://fluxcd.io/flux/installation/)
- **kubectl**: Kubernetes CLI configured for your cluster
- **Git**: For repository operations
- **Kubernetes cluster**: 1.21+ with Gateway API CRDs installed

## Getting Started

### Bootstrap Flux CD

```bash
# Ensure cluster is accessible
kubectl get nodes

# Bootstrap Flux CD (first-time setup)
flux bootstrap github \
  --owner=coryb-xyz \
  --repository=k8s-cdb-sf03-dev \
  --branch=main \
  --path=./flux-system \
  --personal
```

### Verify Deployment

```bash
# Check Flux components
flux check

# Watch Kustomization reconciliation
flux get kustomizations --watch

# Check application status
kubectl get pods -n prod-vanitydomain

# Verify certificate issuance
kubectl get certificate -n prod-vanitydomain
```

### View Gateway Routes

```bash
# List HTTPRoutes
kubectl get httproute -n prod-vanitydomain

# Describe route details
kubectl describe httproute vanitydomain-https -n prod-vanitydomain
```

## Adding a New Application

1. **Create base manifests** in `applications/base/<app-name>/`:
   - `namespace.yaml`
   - `<app-name>.yaml` (Service + Deployment)
   - `kustomization.yaml`
   - Optional: `<app-name>-certificate.yaml`, `<app-name>-httproute.yaml`

2. **Create production overlay** in `applications/overlays/prod/<app-name>/`:
   - `kustomization.yaml` (reference `../../../base/<app-name>` + patches)
   - `<app-name>.yaml` (image tag patch)

3. **Update overlay kustomization** in `applications/overlays/prod/kustomization.yaml`:
   - Add `<app-name>` to resources list

4. **Commit and push**:
   ```bash
   git add applications/base/<app-name> applications/overlays/prod/<app-name>
   git commit -m "Add <app-name> application"
   git push
   ```

5. **Watch Flux reconcile**:
   ```bash
   flux reconcile kustomization applications --with-source
   ```

## Updating Infrastructure

### Upgrade Helm Chart Version

Edit the HelmRelease in `infrastructure/base/<component>/<component>-helm-release.yaml`:

```yaml
spec:
  chart:
    spec:
      version: "NEW_VERSION"  # Update this
```

Commit and Flux will reconcile automatically, or force immediate update:
```bash
flux reconcile helmrelease <component> -n <namespace>
```

### Modify System Resources

Edit patches in `infrastructure/base/system-optimizations/` and commit. Flux applies changes automatically.

## Troubleshooting

### Check Flux Reconciliation Status

```bash
# Overview of all Flux resources
flux get all

# Detailed errors for specific Kustomization
flux logs --kind=Kustomization --name=applications

# Suspend/resume reconciliation
flux suspend kustomization applications
flux resume kustomization applications
```

### Certificate Issues

```bash
# Check Certificate status
kubectl describe certificate vanitydomain-tls-cert -n prod-vanitydomain

# Check CertificateRequest
kubectl get certificaterequest -n prod-vanitydomain

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager
```

### Image Automation Not Working

```bash
# Check ImageRepository scan status
kubectl get imagerepository -n flux-system

# Check ImagePolicy
kubectl get imagepolicy -n flux-system

# Check ImageUpdateAutomation
kubectl describe imageupdateautomation -n flux-system
```

### Gateway/HTTPRoute Issues

```bash
# Check Gateway status
kubectl describe gateway traefik-gateway -n traefik

# Check HTTPRoute status
kubectl get httproute -A

# Check Traefik logs
kubectl logs -n traefik -l app.kubernetes.io/name=traefik
```

## Key Technologies

- **Flux CD v2**: GitOps continuous delivery
- **Kustomize**: Template-free manifest customization
- **Gateway API**: Next-generation Kubernetes ingress
- **cert-manager v1.19**: Automated certificate management
- **Traefik v37**: Gateway controller implementation
- **Let's Encrypt**: Free TLS certificates via ACME protocol

## Security Notes

- Secrets (`flux-system`, `cr-cdb-sf03-dev`) are **NOT stored in Git**
- They must be created manually in the cluster before bootstrapping
- Use Sealed Secrets or external secret management for production

## Contributing

This is a learning/practice repository. Experiment freely with GitOps patterns!

## Resources

- [Flux CD Documentation](https://fluxcd.io/flux/)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Kustomize Documentation](https://kustomize.io/)
