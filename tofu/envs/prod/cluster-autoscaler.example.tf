# Example Cluster Autoscaler Configuration
# Add this to your servers.tf to enable autoscaling

# ----------------------------
# Basic Example (Single Pool)
# ----------------------------

variable "autoscaler_enabled" {
  description = "Enable cluster autoscaler"
  type        = bool
  default     = true
}

variable "autoscaler_nodepools" {
  description = "Autoscaler node pools configuration"
  type = list(object({
    name          = string
    instance_type = string
    region        = string
    min_nodes     = number
    max_nodes     = number
    labels        = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  default = [
    {
      name          = "worker-auto"
      instance_type = "cpx22"  # 3 vCPU, 4GB RAM, 80GB NVMe
      region        = "fsn1"   # Falkenstein
      min_nodes     = 1
      max_nodes     = 5
      labels = {
        "workload-type" = "general"
        "autoscaled"    = "true"
      }
      taints = []
    }
  ]
}

# ----------------------------
# Advanced Example (Multiple Pools)
# ----------------------------

# Uncomment and customize for multi-pool setup:
/*
variable "autoscaler_nodepools" {
  default = [
    # General purpose workers - scales frequently
    {
      name          = "worker-general"
      instance_type = "cpx22"     # 3 vCPU, 4GB RAM
      region        = "fsn1"
      min_nodes     = 2           # Always have 2 for availability
      max_nodes     = 10
      labels = {
        "workload-type" = "general"
        "cost-tier"     = "standard"
      }
      taints = []
    },
    
    # Compute-intensive workers - scales on-demand
    {
      name          = "worker-compute"
      instance_type = "cpx42"     # 8 vCPU, 16GB RAM
      region        = "fsn1"
      min_nodes     = 0           # Scale to zero when not needed
      max_nodes     = 5
      labels = {
        "workload-type" = "compute-intensive"
        "cost-tier"     = "premium"
      }
      taints = [
        {
          key    = "workload-type"
          value  = "compute-intensive"
          effect = "NoSchedule"
        }
      ]
    },
    
    # ARM-based workers - cost-optimized
    {
      name          = "worker-arm"
      instance_type = "cax22"     # ARM64, 4 vCPU, 8GB RAM
      region        = "fsn1"
      min_nodes     = 0
      max_nodes     = 5
      labels = {
        "kubernetes.io/arch" = "arm64"
        "workload-type"      = "cost-optimized"
        "cost-tier"          = "budget"
      }
      taints = []
    },
    
    # High-memory workers - for databases
    {
      name          = "worker-highmem"
      instance_type = "cpx52"     # 16 vCPU, 32GB RAM
      region        = "fsn1"
      min_nodes     = 0
      max_nodes     = 3
      labels = {
        "workload-type" = "high-memory"
        "database"      = "true"
      }
      taints = [
        {
          key    = "workload-type"
          value  = "database"
          effect = "NoSchedule"
        }
      ]
    }
  ]
}
*/

# ----------------------------
# Fine-Tuning Options
# ----------------------------

# Scale down behavior
variable "autoscaler_scale_down_delay" {
  description = "How long after scale up that scale down evaluation resumes"
  type        = string
  default     = "10m"  # Wait 10 minutes after scaling up
}

variable "autoscaler_scale_down_unneeded_time" {
  description = "How long a node should be unneeded before eligible for scale down"
  type        = string
  default     = "10m"  # Node must be idle for 10 minutes
}

# Expander strategy - determines which pool to scale
variable "autoscaler_expander" {
  description = "Node group expander strategy"
  type        = string
  default     = "least-waste"  # Minimize wasted resources
  
  # Options:
  # - "random"       : Random selection
  # - "most-pods"    : Fit the most pending pods
  # - "least-waste"  : Minimize unused resources (recommended)
  # - "price"        : Select cheapest option
  # - "priority"     : Use priority order (requires ConfigMap)
}

# Version configuration
variable "autoscaler_image_tag" {
  description = "Cluster autoscaler image tag (must match k8s version)"
  type        = string
  default     = "v1.35.1"  # For Kubernetes 1.35.x
}

variable "autoscaler_version" {
  description = "Helm chart version"
  type        = string
  default     = "9.46.6"
}

# ----------------------------
# Hetzner Instance Types Reference
# ----------------------------

# Standard (x86):
# - cpx22:  3 vCPU,  4GB RAM,  80GB NVMe - €0.019/hr (~€14/mo)
# - cpx32:  4 vCPU,  8GB RAM, 160GB NVMe - €0.032/hr (~€23/mo)
# - cpx42:  8 vCPU, 16GB RAM, 240GB NVMe - €0.057/hr (~€42/mo)
# - cpx52: 16 vCPU, 32GB RAM, 360GB NVMe - €0.104/hr (~€76/mo)

# ARM (cax):
# - cax22:  4 vCPU,  8GB RAM,  80GB NVMe - €0.011/hr (~€8/mo)  [~50% cheaper!]
# - cax32:  8 vCPU, 16GB RAM, 160GB NVMe - €0.020/hr (~€15/mo)
# - cax42: 16 vCPU, 32GB RAM, 320GB NVMe - €0.038/hr (~€28/mo)

# Shared (cx) - not recommended for production:
# - cx22:  2 vCPU,  4GB RAM,  40GB NVMe - €0.008/hr (~€6/mo)
# - cx32:  4 vCPU,  8GB RAM,  80GB NVMe - €0.014/hr (~€10/mo)

# Note: Prices as of 2025, check Hetzner for current pricing

# ----------------------------
# Example Workload Deployments
# ----------------------------

# General workload (runs on general pool):
/*
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 5
  template:
    spec:
      nodeSelector:
        workload-type: general
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
*/

# Compute-intensive workload (runs on compute pool):
/*
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ml-training
spec:
  replicas: 2
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
      - name: tensorflow
        image: tensorflow/tensorflow:latest
        resources:
          requests:
            cpu: "4"
            memory: "8Gi"
*/

# ARM workload (runs on ARM pool):
/*
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cost-optimized-app
spec:
  replicas: 10
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
      - name: app
        image: arm64v8/nginx
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
*/
