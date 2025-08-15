# Start Minikube cluster
resource "null_resource" "minikube_cluster" {
  provisioner "local-exec" {
    command = <<-EOT
      minikube start \
        --profile=${var.cluster_name} \
        --kubernetes-version=${var.kubernetes_version} \
        --cpus=${var.minikube_cpus} \
        --memory=${var.minikube_memory} \
        --disk-size=${var.minikube_disk_size} \
        --driver=docker \
        --addons=ingress,metrics-server,dashboard
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "minikube delete --profile=microservices-cluster"
  }
}

# Configure kubectl context
resource "null_resource" "kubectl_config" {
  depends_on = [null_resource.minikube_cluster]

  provisioner "local-exec" {
    command = "kubectl config use-context ${var.cluster_name}"
  }
}

# Create namespaces
resource "kubernetes_namespace" "app" {
  depends_on = [null_resource.kubectl_config]

  metadata {
    name = var.environment
    labels = {
      environment = var.environment
      managed_by  = "terraform"
    }
  }
}

resource "kubernetes_namespace" "monitoring" {
  count      = var.enable_monitoring ? 1 : 0
  depends_on = [null_resource.kubectl_config]

  metadata {
    name = "monitoring"
    labels = {
      environment = var.environment
      managed_by  = "terraform"
    }
  }
}

# Create Docker registry secret (disabled when using Makefile/registry-secret)
resource "kubernetes_secret" "docker_registry" {
  count     = 0
  depends_on = [kubernetes_namespace.app]

  metadata {
    name      = "docker-registry-secret"
    namespace = var.environment
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${var.docker_registry}" = {
          username = var.docker_username
          password = var.docker_username
          auth     = base64encode("${var.docker_username}:${var.docker_username}")
        }
      }
    })
  }
}

# Install Prometheus using Helm
resource "helm_release" "prometheus" {
  count      = var.enable_monitoring ? 1 : 0
  depends_on = [kubernetes_namespace.monitoring]

  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  version    = "51.3.0"

  set {
    name  = "grafana.enabled"
    value = "true"
  }

  set {
    name  = "grafana.adminPassword"
    value = "admin123"
  }

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "grafana.service.type"
    value = "NodePort"
  }

  set {
    name  = "grafana.service.nodePort"
    value = "30900"
  }
}

# Provider configuration
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.cluster_name
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = var.cluster_name
  }
}
