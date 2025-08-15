variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "microservices-cluster"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "kubernetes_version" {
  description = "Kubernetes version for Minikube"
  type        = string
  default     = "v1.28.0"
}

variable "minikube_cpus" {
  description = "Number of CPUs for Minikube"
  type        = number
  default     = 4
}

variable "minikube_memory" {
  description = "Memory for Minikube in MB"
  type        = number
  default     = 8192
}

variable "minikube_disk_size" {
  description = "Disk size for Minikube"
  type        = string
  default     = "20g"
}

variable "docker_registry" {
  description = "Docker registry URL"
  type        = string
  default     = "docker.io"
}

variable "docker_username" {
  description = "Docker Hub username"
  type        = string
  sensitive   = true
}

variable "enable_monitoring" {
  description = "Enable Prometheus and Grafana monitoring"
  type        = bool
  default     = true
}