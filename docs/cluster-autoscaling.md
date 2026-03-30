# Cluster Autoscaling for Talos on Hetzner Cloud

This guide explains how to enable and configure cluster autoscaling for your Talos Kubernetes cluster on Hetzner Cloud.

## Overview

The cluster autoscaler automatically adjusts the number of worker nodes in your cluster based on resource demands:

- **Scale Up**: Adds nodes when pods are pending due to insufficient resources
- **Scale Down**: Removes underutilized nodes to save costs

### How It Works

```
Pending Pods → Autoscaler detects → Provisions new Hetzner server → 
Configures with Talos → Joins cluster → Pods scheduled
```

For scale down:
```
Low utilization (>10min) → Autoscaler evaluates → Drains node → 
Deletes Hetzner server → Cost savings
```

### Key Features

- ✅ **Automatic node provisioning** using Hetzner Cloud API
- ✅ **Talos-aware** node configuration
- ✅ **Multiple node pools** with different instance types
- ✅ **Cost optimization** by removing unused nodes
- ✅ **HA-safe** respects pod disruption budgets
- ✅ **Customizable** scaling behavior

## Prerequisites

1. **Talos cluster** deployed on Hetzner Cloud (via `hcloud-talos/talos/hcloud` module)
2. **Hetzner Cloud API token** with read/write permissions
3. **Kubernetes provider** configured in Terraform
4. **Helm provider** configured in Terraform

## Configuration

### Basic Setup

Add to your `servers.tf`:

```hcl
# Enable autoscaler
variable "autoscaler_enabled" {
  default = true
}

# Define autoscaler node pools
variable "autoscaler_nodepools" {
  default = [
    {
      name          = "worker-auto"
      instance_type = "cpx22"    # 3 vCPU, 4GB RAM
      region        = "fsn1"     # Falkenstein
      min_nodes     = 1          # Always keep at least 1 node
      max_nodes     = 10         # Never exceed 10 nodes
      labels        = {
        "workload-type" = "general"
        "autoscaled"    = "true"
      }
      taints        = []
    }
  ]
}
```

### Multi-Pool Configuration

Create specialized node pools for different workloads:

```hcl
variable "autoscaler_nodepools" {
  default = [
    # General purpose workers
    {
      name          = "worker-general"
      instance_type = "cpx22"
      region        = "fsn1"
      min_nodes     = 2
      max_nodes     = 10
      labels = {
        "workload-type" = "general"
      }
      taints = []
    },
    
    # Compute-intensive workers
    {
      name          = "worker-compute"
      instance_type = "cpx42"    # 8 vCPU, 16GB RAM
      region        = "fsn1"
      min_nodes     = 0           # Can scale to zero
      max_nodes     = 5
      labels = {
        "workload-type" = "compute-intensive"
      }
      taints = [
        {
          key    = "workload-type"
          value  = "compute-intensive"
          effect = "NoSchedule"
        }
      ]
    },
    
    # ARM-based workers for cost savings
    {
      name          = "worker-arm"
      instance_type = "cax22"     # ARM64, 4 vCPU, 8GB RAM
      region        = "fsn1"
      min_nodes     = 0
      max_nodes     = 5
      labels = {
        "kubernetes.io/arch" = "arm64"
        "workload-type"      = "arm"
      }
      taints = []
    }
  ]
}
```

### Advanced Configuration

Fine-tune autoscaler behavior:

```hcl
# Scale down timing
variable "autoscaler_scale_down_delay" {
  default = "10m"  # Wait 10min after scale-up before considering scale-down
}

variable "autoscaler_scale_down_unneeded_time" {
  default = "10m"  # Node must be underutilized for 10min before removal
}

# Expander strategy
variable "autoscaler_expander" {
  default = "least-waste"  # Options: random, most-pods, least-waste, price, priority
}

# Version matching
variable "autoscaler_image_tag" {
  default = "v1.35.1"  # Must match your Kubernetes version (1.35.x)
}
```

## Expander Strategies

Choose how the autoscaler selects which node pool to scale:

| Strategy | Description | Use Case |
|----------|-------------|----------|
| `random` | Picks a random node pool | Simple, no preference |
| `most-pods` | Chooses pool that can fit the most pending pods | Maximize pod scheduling |
| `least-waste` | Minimizes unused resources after scaling | Cost optimization (recommended) |
| `price` | Selects cheapest option | Maximum cost savings |
| `priority` | Uses priority order (requires additional config) | Custom preferences |

## Deployment

1. **Apply Terraform configuration:**

```bash
cd tofu/envs/prod
tofu init -upgrade
tofu plan
tofu apply
```

2. **Verify autoscaler deployment:**

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=cluster-autoscaler

# Check logs
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler --tail=50
```

3. **View autoscaler status:**

```bash
kubectl describe configmap cluster-autoscaler-status -n kube-system
```

## Testing Autoscaling

### Test Scale-Up

Create a deployment that requires more resources than available:

```bash
kubectl create namespace autoscaler-test

# Create deployment with 10 replicas requiring significant resources
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: resource-consumer
  namespace: autoscaler-test
spec:
  replicas: 10
  selector:
    matchLabels:
      app: resource-consumer
  template:
    metadata:
      labels:
        app: resource-consumer
    spec:
      containers:
      - name: stress
        image: polinux/stress
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
        command: ["stress"]
        args: ["--cpu", "1", "--timeout", "3600s"]
EOF
```

Monitor the autoscaler:

```bash
# Watch for pending pods
kubectl get pods -n autoscaler-test -w

# Watch autoscaler logs
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler -f

# Watch nodes being added
watch kubectl get nodes
```

Expected behavior:
1. Pods go to `Pending` state (insufficient resources)
2. Autoscaler detects pending pods (~30s)
3. New Hetzner server provisioned (~60-90s)
4. Node configured with Talos and joins cluster (~30s)
5. Pods scheduled on new node

### Test Scale-Down

Clean up the test deployment:

```bash
kubectl delete namespace autoscaler-test
```

Monitor scale down (takes ~10-20 minutes by default):

```bash
# Watch nodes being removed
watch kubectl get nodes

# Check autoscaler logs for scale-down decisions
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler -f | grep scale
```

## Using Specific Node Pools

### Schedule on Autoscaled Nodes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      nodeSelector:
        autoscaled: "true"
      containers:
      - name: app
        image: nginx
```

### Schedule on Compute-Intensive Nodes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: compute-heavy-app
spec:
  template:
    spec:
      nodeSelector:
        workload-type: compute-intensive
      tolerations:
      - key: workload-type
        operator: Equal
        value: compute-intensive
        effect: NoSchedule
      containers:
      - name: app
        image: my-compute-app
        resources:
          requests:
            cpu: "4"
            memory: "8Gi"
```

### Schedule on ARM Nodes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: arm-compatible-app
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
      - name: app
        image: arm64v8/nginx
```

## Monitoring

### Key Metrics to Watch

```bash
# View autoscaler status
kubectl get configmap cluster-autoscaler-status -n kube-system -o yaml

# Check recent scaling activities
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler --tail=100 | grep "Scaling"

# View current node count
kubectl get nodes --no-headers | wc -l

# Check pending pods
kubectl get pods --all-namespaces --field-selector=status.phase=Pending
```

### Common Log Messages

| Message | Meaning |
|---------|---------|
| `Scale-up: group <name> max size reached` | Node pool at max_nodes limit |
| `Scale-down: node <name> is unneeded` | Node eligible for removal |
| `Scale-down: node <name> was unneeded for <time>` | Node will be removed soon |
| `Scaled up group <name> to <count>` | New node being provisioned |
| `Successfully added node <name>` | Node joined cluster |

## Troubleshooting

### Pods Stay Pending

**Symptoms:**
- Pods remain in `Pending` state
- No new nodes provisioned

**Possible causes and solutions:**

1. **Max nodes reached:**
   ```bash
   # Check autoscaler logs
   kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler | grep "max size"
   ```
   Solution: Increase `max_nodes` in your nodepool config

2. **API token invalid:**
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler | grep "authentication"
   ```
   Solution: Verify `hcloud_token` is correct and has write permissions

3. **Resource requests too large:**
   ```bash
   kubectl describe pod <pending-pod>
   ```
   Solution: Choose larger instance type or reduce pod resource requests

4. **Hetzner API limits:**
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler | grep "rate limit"
   ```
   Solution: Wait for rate limit to reset, or contact Hetzner support

### Nodes Not Scaling Down

**Symptoms:**
- Underutilized nodes remain in cluster
- No scale-down activity in logs

**Possible causes and solutions:**

1. **Pods without disruption budgets:**
   ```bash
   # Check which pods are blocking scale-down
   kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler | grep "not scaled"
   ```
   
2. **System pods on node:**
   - By default, autoscaler won't remove nodes with kube-system pods
   - This is usually correct behavior

3. **Local storage:**
   - Nodes with local volumes won't be removed
   - Move to PVCs if you need autoscaling

4. **Recently scaled up:**
   - Must wait `autoscaler_scale_down_delay` (default 10m) after scale-up

### Node Provisioning Fails

**Check Hetzner Cloud status:**

```bash
# List recent servers
hcloud server list

# Check for failed server creations
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler | grep -i error
```

**Common issues:**
- Out of stock for instance type in region
- Network or firewall misconfiguration
- Insufficient permissions in API token

## Cost Optimization Tips

1. **Use ARM instances** where possible (CAX series) - up to 50% cheaper
2. **Set appropriate min_nodes:**
   - Use `0` for specialized workloads
   - Use `1-2` for general workloads to avoid cold starts
3. **Tune scale-down timing:**
   - Shorter times = more aggressive cost savings
   - Longer times = better performance, less churn
4. **Use `least-waste` expander** for optimal resource utilization
5. **Monitor usage patterns** and adjust pool sizes accordingly

## Advanced: Priority-Based Expander

For complex scenarios, use priority expander:

```hcl
variable "autoscaler_expander" {
  default = "priority"
}
```

Create priority ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-autoscaler-priority-expander
  namespace: kube-system
data:
  priorities: |
    10:
      - worker-arm.*          # Prefer ARM (cheapest)
    20:
      - worker-general.*      # Then general purpose
    50:
      - worker-compute.*      # Last resort: expensive compute nodes
```

## Integration with External Secrets Operator

The autoscaler configuration is compatible with your existing External Secrets Operator setup. You can store the Hetzner token in GCP Secret Manager:

```bash
# Store token in Secret Manager
echo -n "your-hcloud-token" | gcloud secrets create hcloud-token \
    --data-file=- \
    --project=malachowski
```

Create ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: hetzner-api-token
  namespace: kube-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcpsm-secret-store
    kind: ClusterSecretStore
  target:
    name: hetzner-api-token
    creationPolicy: Owner
  data:
  - secretKey: token
    remoteRef:
      key: hcloud-token
```

Then update Terraform to skip creating the secret:

```hcl
# Comment out or remove kubernetes_secret.hetzner_api_token resource
# It will be created by External Secrets Operator instead
```

## Security Considerations

1. **API Token Security:**
   - Store in Kubernetes secret (encrypted at rest if enabled)
   - Or use External Secrets Operator with GCP Secret Manager
   - Never commit tokens to version control

2. **RBAC:**
   - Autoscaler runs with minimal permissions
   - Only has access to kube-system namespace secrets

3. **Network Security:**
   - Autoscaled nodes join the same private network
   - Firewall rules apply automatically

4. **Node Security:**
   - All nodes use Talos (immutable, secure by default)
   - Same security posture as manually provisioned nodes

## Disabling Autoscaler

To disable autoscaling:

```hcl
variable "autoscaler_enabled" {
  default = false
}
```

Then apply:

```bash
tofu apply
```

This will:
1. Remove the autoscaler deployment
2. Remove API token secrets
3. Keep existing autoscaled nodes running

To also remove autoscaled nodes, manually drain and delete them:

```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node-name>
hcloud server delete <server-name>
```

## References

- [Kubernetes Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
- [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
- [Hetzner Cloud API](https://docs.hetzner.cloud)
- [Talos Linux Documentation](https://www.talos.dev)
- [hcloud-talos Terraform Module](https://registry.terraform.io/modules/hcloud-talos/talos/hcloud)

## Support

For issues specific to this implementation:
1. Check autoscaler logs first
2. Review Hetzner Cloud console for server provisioning status
3. Verify Talos cluster health
4. Open an issue with relevant logs and configuration

For general cluster autoscaler questions, refer to the [upstream documentation](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler).
