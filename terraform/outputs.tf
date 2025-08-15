output "cluster_name" {
  description = "Name of the Kubernetes cluster"
  value       = var.cluster_name
}

output "namespace" {
  description = "Application namespace"
  value       = kubernetes_namespace.app.metadata[0].name
}

output "minikube_ip" {
  description = "Minikube IP address"
  value       = "Run: minikube ip --profile=${var.cluster_name}"
}

output "grafana_url" {
  description = "Grafana URL"
  value       = var.enable_monitoring ? "http://$(minikube ip --profile=${var.cluster_name}):30900" : "Monitoring disabled"
}

output "services_info" {
  description = "Services access information"
  value = {
    python_service = "http://$(minikube ip --profile=${var.cluster_name}):30001"
    nodejs_service = "http://$(minikube ip --profile=${var.cluster_name}):30002"
    postgres       = "postgresql://$(minikube ip --profile=${var.cluster_name}):30432"
  }
}