# Cluster Autoscaler Configuration for Talos on Hetzner Cloud
# This enables automatic scaling of worker nodes based on cluster demand

# Variables for configuring autoscaling behavior
variable "autoscaler_enabled" {
  description = "Enable cluster autoscaler"
  type        = bool
  default     = false
}

variable "autoscaler_nodepools" {
  description = "Cluster autoscaler nodepools configuration"
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
  default = []

  validation {
    condition = alltrue([
      for np in var.autoscaler_nodepools :
      np.min_nodes >= 0 && np.max_nodes >= np.min_nodes
    ])
    error_message = "Each nodepool must have min_nodes >= 0 and max_nodes >= min_nodes"
  }
}

variable "autoscaler_version" {
  description = "Version of cluster-autoscaler Helm chart to deploy"
  type        = string
  default     = "9.46.6"
}

variable "autoscaler_image_tag" {
  description = "Tag of cluster-autoscaler image to use (should match k8s version)"
  type        = string
  default     = "v1.35.1" # Matches kubernetes v1.35.x
}

variable "autoscaler_scale_down_delay" {
  description = "How long after scale up that scale down evaluation resumes"
  type        = string
  default     = "10m"
}

variable "autoscaler_scale_down_unneeded_time" {
  description = "How long a node should be unneeded before it is eligible for scale down"
  type        = string
  default     = "10m"
}

variable "autoscaler_expander" {
  description = "Type of node group expander to use (random, most-pods, least-waste, price, priority)"
  type        = string
  default     = "least-waste"

  validation {
    condition     = contains(["random", "most-pods", "least-waste", "price", "priority"], var.autoscaler_expander)
    error_message = "Expander must be one of: random, most-pods, least-waste, price, priority"
  }
}

# Local variables for autoscaler configuration
locals {
  # Generate Talos machine configuration for autoscaled worker nodes
  autoscaler_enabled = var.autoscaler_enabled && length(var.autoscaler_nodepools) > 0

  # Cluster configuration passed to autoscaler for node provisioning
  cluster_config = local.autoscaler_enabled ? {
    talosVersion      = module.talos.talos_version
    kubernetesVersion = module.talos.kubernetes_version
    clusterName       = module.talos.cluster_name
    clusterEndpoint   = module.talos.cluster_endpoint
    
    # Machine configuration patches for autoscaled nodes
    machineConfigPatches = {
      worker = {
        machine = {
          kubelet = {
            extraArgs = {
              "cloud-provider"             = "external"
              "rotate-server-certificates" = "true"
            }
          }
          network = {
            hostname = ""  # Will be set by autoscaler
          }
        }
        cluster = {
          network = {
            dnsDomain = "cluster.local"
            cni = {
              name = "none"  # Using Cilium
            }
          }
        }
      }
    }
    
    # Node configurations per nodepool
    nodeConfigs = {
      for np in var.autoscaler_nodepools :
      np.name => {
        labels = np.labels
        taints = np.taints
      }
    }
  } : null
}

# Kubernetes Secret containing Hetzner Cloud API token for autoscaler
resource "kubernetes_secret" "hetzner_api_token" {
  count = local.autoscaler_enabled ? 1 : 0

  metadata {
    name      = "hetzner-api-token"
    namespace = "kube-system"
  }

  data = {
    token = var.hcloud_token
  }

  depends_on = [module.talos]
}

# Kubernetes Secret containing cluster configuration for autoscaler
resource "kubernetes_secret" "cluster_config" {
  count = local.autoscaler_enabled ? 1 : 0

  metadata {
    name      = "cluster-autoscaler-config"
    namespace = "kube-system"
  }

  data = {
    config = base64encode(jsonencode(local.cluster_config))
  }

  depends_on = [module.talos]
}

# Helm release for Cluster Autoscaler
resource "helm_release" "autoscaler" {
  count = local.autoscaler_enabled ? 1 : 0

  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = var.autoscaler_version

  values = [yamlencode({
    # Cloud provider configuration
    cloudProvider = "hetzner"
    
    # Auto-discovery configuration
    autoDiscovery = {
      clusterName = module.talos.cluster_name
    }

    # Image configuration
    image = {
      tag = var.autoscaler_image_tag
    }

    # Resource requests and limits
    resources = {
      limits = {
        cpu    = "100m"
        memory = "300Mi"
      }
      requests = {
        cpu    = "100m"
        memory = "300Mi"
      }
    }

    # Hetzner Cloud API token from secret
    extraEnvSecrets = {
      HCLOUD_TOKEN = {
        name = kubernetes_secret.hetzner_api_token[0].metadata[0].name
        key  = "token"
      }
    }

    # Additional environment variables
    extraEnv = {
      HCLOUD_NETWORK        = tostring(module.talos.hetzner_network_id)
      HCLOUD_CLUSTER_CONFIG = base64encode(jsonencode(local.cluster_config))
    }

    # Autoscaling groups configuration
    autoscalingGroups = [
      for np in var.autoscaler_nodepools : {
        name         = np.name
        maxSize      = np.max_nodes
        minSize      = np.min_nodes
        instanceType = np.instance_type
        region       = np.region
      }
    ]

    # Additional arguments for fine-tuning
    extraArgs = {
      v                               = 4  # Verbosity level
      stderrthreshold                 = "info"
      logtostderr                     = true
      scale-down-enabled              = true
      scale-down-delay-after-add      = var.autoscaler_scale_down_delay
      scale-down-unneeded-time        = var.autoscaler_scale_down_unneeded_time
      scale-down-utilization-threshold = 0.5
      max-node-provision-time         = "15m"
      balance-similar-node-groups     = true
      expander                        = var.autoscaler_expander
      skip-nodes-with-local-storage   = false
      skip-nodes-with-system-pods     = true
    }

    # RBAC configuration
    rbac = {
      create = true
      serviceAccount = {
        create = true
        name   = "cluster-autoscaler"
      }
    }

    # Pod security context
    podSecurityContext = {
      runAsNonRoot = true
      runAsUser    = 65534
      fsGroup      = 65534
    }

    # Node selector to run on control plane
    nodeSelector = {
      "node-role.kubernetes.io/control-plane" = "true"
    }

    # Tolerations to run on control plane
    tolerations = [
      {
        key      = "node-role.kubernetes.io/control-plane"
        operator = "Exists"
        effect   = "NoSchedule"
      }
    ]
  })]

  depends_on = [
    module.talos,
    kubernetes_secret.hetzner_api_token,
    kubernetes_secret.cluster_config
  ]
}

# Outputs
output "autoscaler_enabled" {
  description = "Whether cluster autoscaler is enabled"
  value       = local.autoscaler_enabled
}

output "autoscaler_nodepools" {
  description = "Configured autoscaler nodepools"
  value       = var.autoscaler_nodepools
}
