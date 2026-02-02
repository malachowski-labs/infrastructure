# External Secrets Operator with Workload Identity Federation

This configuration sets up External Secrets Operator (ESO) to access GCP Secret Manager using Workload Identity Federation, avoiding the need for service account keys. The OIDC discovery is exposed via a Kubernetes service instead of cloud storage.

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│   Kubernetes Cluster (Talos)                       │
│                                                     │
│  ┌───────────────────────────────────────────────┐ │
│  │  API Server (OIDC Issuer)                     │ │
│  │  - Issues service account tokens              │ │
│  │  - Exposes /openid/v1/jwks                    │ │
│  └───────────────┬───────────────────────────────┘ │
│                  │                                  │
│  ┌───────────────▼───────────────────────────────┐ │
│  │  OIDC Discovery Service (Nginx)               │ │
│  │  - /.well-known/openid-configuration          │ │
│  │  - Proxies /openid/v1/jwks → API Server       │ │
│  │  - Exposed via Ingress (oidc.malachowski.me)  │ │
│  └───────────────┬───────────────────────────────┘ │
│                  │                                  │
│  ┌───────────────▼───────────────────────────────┐ │
│  │  External Secrets Operator                    │ │
│  │  (ServiceAccount with OIDC token)             │ │
│  └───────────────┬───────────────────────────────┘ │
│                  │ OIDC Token                       │
└──────────────────┼──────────────────────────────────┘
                   │
                   │ Exchange for GCP Access Token
                   ▼
┌─────────────────────────────────────────────────────┐
│   GCP Workload Identity Pool                        │
│   ┌─────────────────────────────────────────────┐   │
│   │  OIDC Provider                              │   │
│   │  - Fetches from oidc.malachowski.me         │   │
│   │  - Validates OIDC token signature           │   │
│   └─────────────┬───────────────────────────────┘   │
│                 │                                   │
│                 ▼                                   │
│   ┌─────────────────────────────────────────────┐   │
│   │  GCP Service Account                        │   │
│   │  (Secret Manager Access)                    │   │
│   └─────────────┬───────────────────────────────┘   │
└─────────────────┼───────────────────────────────────┘
                  │
                  ▼
          ┌──────────────────┐
          │  GCP Secret      │
          │  Manager         │
          └──────────────────┘
```

## Components

### 1. Talos API Server OIDC Configuration
- **Issuer**: `https://oidc.malachowski.me`
- **JWKS URI**: `https://oidc.malachowski.me/openid/v1/jwks`
- **Purpose**: API server signs service account tokens with configured issuer

### 2. OIDC Discovery Service (Kubernetes)
- **Namespace**: `oidc-discovery`
- **Image**: `nginx:alpine`
- **Endpoints**:
  - `/.well-known/openid-configuration` - Discovery document (from ConfigMap)
  - `/openid/v1/jwks` - Proxied from API server
- **Ingress**: `oidc.malachowski.me` (TLS via cert-manager)

### 3. GCP Service Account
- **Name**: `external-secrets-operator@malachowski.iam.gserviceaccount.com`
- **Permissions**: `roles/secretmanager.secretAccessor`
- **Usage**: Used by ESO to access secrets in GCP Secret Manager

### 4. Workload Identity Pool & Provider
- **Pool**: `kubernetes-pool`
- **Provider**: `kubernetes-oidc-provider`
- **OIDC Issuer**: `https://oidc.malachowski.me`
- **Purpose**: Maps Kubernetes service accounts to GCP service accounts

### 5. External Secrets Operator
- **Namespace**: `external-secrets`
- **ServiceAccount**: `external-secrets-operator`
- **Annotation**: Links K8s SA to GCP SA via `iam.gke.io/gcp-service-account`

## Setup Instructions

### Prerequisites

1. **DNS Configuration**: Create an A/CNAME record for `oidc.malachowski.me` pointing to your cluster ingress IP
2. **cert-manager**: Ensure cert-manager is installed with a ClusterIssuer named `letsencrypt-prod`
3. **Traefik Ingress**: Ensure Traefik is configured as your ingress controller

### Step 1: Apply Terraform Configuration

```bash
cd tofu/envs/prod
tofu init
tofu plan
tofu apply
```

This will create:
- Talos API server configuration with OIDC issuer
- OIDC discovery service (Nginx) in Kubernetes
- Ingress to expose OIDC endpoints publicly
- GCP Service Account
- Workload Identity Pool and Provider
- IAM bindings
- External Secrets Operator Helm release
- ClusterSecretStore resource

### Step 2: Verify DNS and TLS

After applying, wait for DNS propagation and cert-manager to issue certificates:

```bash
# Check ingress
kubectl get ingress -n oidc-discovery

# Check certificate
kubectl get certificate -n oidc-discovery

# Wait for certificate to be ready
kubectl wait --for=condition=Ready certificate/oidc-discovery-tls -n oidc-discovery --timeout=5m
```

### Step 3: Verify OIDC Configuration

Test the OIDC endpoints:

```bash
# Test discovery document
curl https://oidc.malachowski.me/.well-known/openid-configuration | jq

# Test JWKS (proxied from API server)
curl https://oidc.malachowski.me/openid/v1/jwks | jq
```

Expected discovery document:
```json
{
  "issuer": "https://oidc.malachowski.me",
  "jwks_uri": "https://oidc.malachowski.me/openid/v1/jwks",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
```

### Step 4: Verify External Secrets Operator

Check that ESO is running:

```bash
kubectl get pods -n external-secrets
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

Check the ClusterSecretStore status:

```bash
kubectl get clustersecretstore gcpsm-secret-store
kubectl describe clustersecretstore gcpsm-secret-store
```

Expected status:
```yaml
Status:
  Conditions:
    Status: True
    Type:   Ready
```

## Usage Example

### Create a Secret in GCP Secret Manager

```bash
echo -n "my-secret-value" | gcloud secrets create my-app-secret \
    --data-file=- \
    --project=malachowski
```

### Create an ExternalSecret Resource

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcpsm-secret-store
    kind: ClusterSecretStore
  target:
    name: my-app-secret
    creationPolicy: Owner
  data:
  - secretKey: password
    remoteRef:
      key: my-app-secret
```

Apply it:

```bash
kubectl apply -f externalsecret.yaml
```

Verify the secret was created:

```bash
kubectl get secret my-app-secret -o yaml
kubectl get externalsecret my-app-secret
```

## Troubleshooting

### OIDC Discovery Service Not Accessible

1. **Check OIDC Discovery pods**:
   ```bash
   kubectl get pods -n oidc-discovery
   kubectl logs -n oidc-discovery -l app=oidc-discovery
   ```

2. **Check Ingress**:
   ```bash
   kubectl get ingress -n oidc-discovery
   kubectl describe ingress oidc-discovery -n oidc-discovery
   ```

3. **Check Certificate**:
   ```bash
   kubectl get certificate -n oidc-discovery
   kubectl describe certificate oidc-discovery-tls -n oidc-discovery
   ```

4. **Test from inside cluster**:
   ```bash
   kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
     curl http://oidc-discovery.oidc-discovery.svc.cluster.local/.well-known/openid-configuration
   ```

### ESO Cannot Authenticate to GCP

1. **Check ServiceAccount annotation**:
   ```bash
   kubectl get sa external-secrets-operator -n external-secrets -o yaml
   ```
   Should have annotation: `iam.gke.io/gcp-service-account: external-secrets-operator@malachowski.iam.gserviceaccount.com`

2. **Verify Workload Identity binding**:
   ```bash
   gcloud iam service-accounts get-iam-policy \
       external-secrets-operator@malachowski.iam.gserviceaccount.com
   ```

3. **Check GCP can access OIDC endpoints**:
   ```bash
   # From your local machine (simulates GCP accessing the endpoint)
   curl https://oidc.malachowski.me/.well-known/openid-configuration
   curl https://oidc.malachowski.me/openid/v1/jwks
   ```

4. **View ESO logs**:
   ```bash
   kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100
   ```

5. **Check API server configuration**:
   ```bash
   # Verify API server has correct OIDC flags
   kubectl get pods -n kube-system -l component=kube-apiserver -o yaml | grep service-account
   ```

### JWKS Endpoint Returns Error

If the JWKS endpoint returns an error, check the API server:

```bash
# Test direct access to API server JWKS
kubectl get --raw /openid/v1/jwks | jq

# Check nginx proxy logs
kubectl logs -n oidc-discovery -l app=oidc-discovery
```

### Permission Denied Errors

Verify the GCP service account has Secret Manager access:

```bash
gcloud projects get-iam-policy malachowski \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:external-secrets-operator@malachowski.iam.gserviceaccount.com"
```

## Security Considerations

1. **No Service Account Keys**: This setup uses Workload Identity Federation, eliminating the need to manage and rotate service account keys.

2. **Namespace Isolation**: The attribute condition in the Workload Identity Provider ensures only service accounts in the `external-secrets` namespace can authenticate.

3. **Public OIDC Endpoints**: The OIDC discovery endpoints must be publicly accessible for GCP to verify tokens. This is safe as they only contain:
   - Discovery metadata (issuer, algorithms)
   - Public keys (JWKS) - no private keys are exposed

4. **Least Privilege**: The GCP service account only has `secretmanager.secretAccessor` role, limiting access to read secrets only.

5. **TLS Required**: The OIDC endpoints are exposed via HTTPS with cert-manager, ensuring secure communication.

## How It Works

### Token Exchange Flow

1. **ESO requests secret from GCP Secret Manager**
2. **Kubernetes API issues OIDC token** to ESO pod's service account with:
   - Issuer: `https://oidc.malachowski.me`
   - Audience: GCP Workload Identity Pool
   - Claims: namespace, pod, service account name
3. **ESO sends OIDC token to GCP**
4. **GCP Workload Identity verifies token**:
   - Fetches discovery document from `https://oidc.malachowski.me/.well-known/openid-configuration`
   - Fetches JWKS from `https://oidc.malachowski.me/openid/v1/jwks`
   - Validates token signature using public key
   - Checks issuer, audience, and expiration
5. **GCP maps K8s SA to GCP SA** using attribute conditions
6. **GCP issues short-lived access token** for the mapped GCP service account
7. **ESO uses access token to fetch secret** from Secret Manager

### Why Nginx Proxy?

The OIDC discovery service uses Nginx to:
- Serve static discovery document from ConfigMap
- Proxy JWKS requests to the API server (since it's not directly accessible from internet)
- Add proper CORS headers
- Provide a stable, cacheable endpoint

## Maintenance

### Rotating Service Account Keys

Kubernetes automatically rotates service account signing keys. Since we proxy the JWKS from the API server, no manual updates are needed.

### Updating External Secrets Operator

Update the Helm chart version in `external-secret-operator.tf` and run:

```bash
tofu apply
```

### Updating OIDC Discovery Configuration

To update the discovery document:

```bash
# Edit the ConfigMap
kubectl edit configmap oidc-discovery -n oidc-discovery

# Restart pods to pick up changes
kubectl rollout restart deployment oidc-discovery -n oidc-discovery
```

### Adding More Secret Stores

You can create additional ClusterSecretStores or namespaced SecretStores for different GCP projects or other providers.

## Advanced Configuration

### Using Custom Domain

To use a different domain for OIDC:

1. Update `cluster_issuer_url` in `external-secret-operator.tf`
2. Update API server flags in `servers.tf`
3. Update Ingress host in `external-secret-operator.tf`
4. Apply Terraform changes

### High Availability

The OIDC discovery service is deployed with 2 replicas by default. To increase:

```hcl
spec {
  replicas = 3  # Increase replicas
  # ...
}
```

### Monitoring

Monitor the OIDC discovery service:

```bash
# Prometheus metrics (if installed)
kubectl port-forward -n oidc-discovery svc/oidc-discovery 8080:80

# Check uptime
kubectl get deployment -n oidc-discovery

# Monitor pod restarts
kubectl get pods -n oidc-discovery -w
```

## References

- [External Secrets Operator Documentation](https://external-secrets.io/)
- [GCP Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [Kubernetes OIDC Tokens](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection)
- [GCP Secret Manager](https://cloud.google.com/secret-manager/docs)
- [Talos Kubernetes Configuration](https://www.talos.dev/v1.11/reference/configuration/)

## PS: How to Enter New Line in OpenTofu Prompt Field

**Answer**: Use `Shift + Enter` in most terminals and IDEs to create a new line in multi-line string input fields. For heredoc syntax in Terraform:

```hcl
variable "multiline" {
  default = <<-EOT
    Line 1
    Line 2
    Line 3
  EOT
}
```

Or using `\n` escape sequences:
```hcl
value = "Line 1\nLine 2\nLine 3"
```
