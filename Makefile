# Makefile for Kubernetes Terraform Deployment

.PHONY: help
help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

# Variables
ENVIRONMENT ?= dev
CLUSTER_NAME ?= microservices-cluster
KUBERNETES_VERSION ?= v1.28.0
MINIKUBE_CPUS ?= 4
MINIKUBE_MEMORY ?= 8192
MINIKUBE_DISK_SIZE ?= 20g
DOCKER_USERNAME ?= myuser
DOCKER_REGISTRY ?= docker.io
TERRAFORM_DIR = terraform
SERVICES_DIR = services
SCRIPTS_DIR = scripts

# Prerequisites check
.PHONY: check-prerequisites
check-prerequisites: check-docker-login ## Check if all required tools are installed
	@echo "Checking prerequisites..."
	@command -v docker >/dev/null 2>&1 || { echo "Docker is required but not installed."; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed."; exit 1; }
	@command -v minikube >/dev/null 2>&1 || { echo "Minikube is required but not installed."; exit 1; }
	@command -v terraform >/dev/null 2>&1 || { echo "Terraform is required but not installed."; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "Helm is required but not installed."; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required but not installed."; exit 1; }
	@echo "✓ All prerequisites are installed"

# Check Docker login status
.PHONY: check-docker-login
check-docker-login: ## Verify Docker is running and user is logged in
	@docker info >/dev/null 2>&1 || { echo "Docker is not running or not accessible"; exit 1; }
	@if [ ! -f "$$HOME/.docker/config.json" ]; then \
		echo "ERROR: Not logged into Docker. Run 'docker login' first."; exit 1; \
	fi
	@echo "✓ Docker is running and authenticated"

# Set the docker registry secret
.PHONY: registry-secret
registry-secret: ## Create/refresh imagePullSecret from local docker login
	@# Ensure namespace exists
	kubectl create namespace $(ENVIRONMENT) --dry-run=client -o yaml | kubectl apply -f -
	@# Require docker login
	@if [ ! -f "$$HOME/.docker/config.json" ]; then \
	  echo "ERROR: $$HOME/.docker/config.json not found. Run 'docker login' first."; exit 1; \
	fi
	@# Create/refresh the k8s secret from the logged-in docker credentials
	kubectl -n $(ENVIRONMENT) create secret generic docker-registry-secret \
	  --type=kubernetes.io/dockerconfigjson \
	  --from-file=.dockerconfigjson=$$HOME/.docker/config.json \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo "✓ Docker registry secret created/updated in namespace $(ENVIRONMENT)"

# Install dependencies
.PHONY: install-deps
install-deps: ## Create/use local .venv and install Python dependencies
	@if [ ! -d ".venv" ]; then python3 -m venv .venv; fi
	@. .venv/bin/activate && .venv/bin/python -m pip install --upgrade pip setuptools
	@. .venv/bin/activate && .venv/bin/pip install jinja2 pyyaml

# Terraform operations
.PHONY: start-minikube
start-minikube: ## Start Minikube cluster (idempotent)
	@echo "Checking minikube status for profile $(CLUSTER_NAME)..."
	@if minikube status --profile=$(CLUSTER_NAME) >/dev/null 2>&1; then \
	  echo "minikube profile $(CLUSTER_NAME) is already running"; \
	else \
	  echo "Starting minikube profile $(CLUSTER_NAME)..." ; \
	  minikube start --profile=$(CLUSTER_NAME) --kubernetes-version=$(KUBERNETES_VERSION) --cpus=$(MINIKUBE_CPUS) --memory=$(MINIKUBE_MEMORY) --disk-size=$(MINIKUBE_DISK_SIZE) --driver=docker --addons=ingress,metrics-server,dashboard ; \
	fi

.PHONY: terraform-init
terraform-init: ## Initialize Terraform
	cd $(TERRAFORM_DIR) && terraform init

.PHONY: terraform-plan
terraform-plan: terraform-init ## Plan Terraform changes
	cd $(TERRAFORM_DIR) && terraform plan -var="docker_username=$(DOCKER_USERNAME)"

.PHONY: terraform-apply
terraform-apply: terraform-init ## Apply Terraform changes
	cd $(TERRAFORM_DIR) && terraform apply -var="docker_username=$(DOCKER_USERNAME)" -auto-approve

.PHONY: terraform-destroy
terraform-destroy: ## Destroy Terraform resources
	cd $(TERRAFORM_DIR) && terraform destroy -var="docker_username=$(DOCKER_USERNAME)" -auto-approve

# Docker operations
.PHONY: docker-build
docker-build: ## Build Docker images
	@echo "Building Python service..."
	docker build -t $(DOCKER_USERNAME)/python-service:latest $(SERVICES_DIR)/python-service/
	docker tag $(DOCKER_USERNAME)/python-service:latest $(DOCKER_USERNAME)/python-service:$(ENVIRONMENT)
	@echo "Building Node.js service..."
	docker build -t $(DOCKER_USERNAME)/nodejs-service:latest $(SERVICES_DIR)/nodejs-service/
	docker tag $(DOCKER_USERNAME)/nodejs-service:latest $(DOCKER_USERNAME)/nodejs-service:$(ENVIRONMENT)

.PHONY: docker-push
docker-push: check-docker-login docker-build ## Push Docker images to registry
	@echo "Pushing images to Docker Hub..."
	docker push $(DOCKER_USERNAME)/python-service:latest
	docker push $(DOCKER_USERNAME)/python-service:$(ENVIRONMENT)
	docker push $(DOCKER_USERNAME)/nodejs-service:latest
	docker push $(DOCKER_USERNAME)/nodejs-service:$(ENVIRONMENT)

# Kubernetes operations
.PHONY: render-templates
render-templates: ## Render Kubernetes manifests from templates
	@echo "Rendering templates for $(ENVIRONMENT)..."
	DOCKER_USERNAME=$(DOCKER_USERNAME) DOCKER_REGISTRY=$(DOCKER_REGISTRY) \
	python3 $(SCRIPTS_DIR)/render-templates.py --environment $(ENVIRONMENT)

.PHONY: deploy
deploy: registry-secret ## Deploy to Kubernetes (ensures imagePullSecret exists)
# Use kustomize rendering when present. Applying the directory with -f caused the
# local `kustomization.yaml` to be treated as a Kubernetes resource (Kustomization CRD)
# which is incorrect for local deployments. Use `kubectl apply -k` to apply the
# local kustomization or fall back to applying YAML files directly.
	@if kubectl apply -k kubernetes/rendered/$(ENVIRONMENT)/ >/dev/null 2>&1; then \
		kubectl apply -k kubernetes/rendered/$(ENVIRONMENT)/ ; \
	else \
		find kubernetes/rendered/$(ENVIRONMENT) -maxdepth 1 -type f -name '*.yaml' -not -name 'kustomization.yaml' -print0 | xargs -0 -r kubectl apply -f ; \
	fi

.PHONY: undeploy
undeploy: ## Remove deployment from Kubernetes
	@kubectl delete -f kubernetes/rendered/$(ENVIRONMENT)/

.PHONY: setup-monitoring
setup-monitoring: ## Setup Prometheus and Grafana monitoring
	bash $(SCRIPTS_DIR)/setup-monitoring.sh

# Combined operations
.PHONY: setup-cluster
setup-cluster: check-prerequisites start-minikube terraform-apply ## Setup Minikube cluster with Terraform

.PHONY: build-and-push
build-and-push: docker-build docker-push ## Build and push Docker images

.PHONY: full-deploy
full-deploy: check-prerequisites install-deps setup-cluster build-and-push registry-secret render-templates deploy setup-monitoring ## Complete deployment from scratch
	@echo "✅ Full deployment completed!"
	@echo "Python Service: http://$$(minikube ip):30001"
	@echo "Node.js Service: http://$$(minikube ip):30002"
	@echo "Grafana: http://$$(minikube ip):30900 (admin/admin123)"

.PHONY: quick-deploy
quick-deploy: registry-secret render-templates deploy ## Quick deployment (assumes images exist)

# Utility commands
.PHONY: logs-python
logs-python: ## Show Python service logs
	kubectl -n $(ENVIRONMENT) logs -f deployment/python-service-deployment

.PHONY: logs-nodejs
logs-nodejs: ## Show Node.js service logs
	kubectl -n $(ENVIRONMENT) logs -f deployment/nodejs-service-deployment

.PHONY: logs-postgres
logs-postgres: ## Show PostgreSQL logs
	kubectl -n $(ENVIRONMENT) logs -f statefulset/postgres

.PHONY: status
status: ## Show deployment status
	@echo "=== Pods ==="
	kubectl -n $(ENVIRONMENT) get pods
	@echo "\n=== Services ==="
	kubectl -n $(ENVIRONMENT) get services
	@echo "\n=== StatefulSets ==="
	kubectl -n $(ENVIRONMENT) get statefulsets
	@echo "\n=== Ingress ==="
	kubectl -n $(ENVIRONMENT) get ingress

.PHONY: dashboard
dashboard: ## Open Kubernetes dashboard
	minikube dashboard

.PHONY: grafana
grafana: ## Open Grafana dashboard
	@echo "Opening Grafana at http://$$(minikube ip):30900"
	@echo "Username: admin, Password: admin123"
	open http://$$(minikube ip):30900 || xdg-open http://$$(minikube ip):30900

.PHONY: test-services
test-services: ## Test all services
	@echo "Testing Python service..."
	curl -s http://$$(minikube ip --profile=microservices-cluster):30001/health | jq .
	@echo "\nTesting Node.js service..."
	curl -s http://$$(minikube ip --profile=microservices-cluster):30002/status | jq .

.PHONY: test-deployment
test-deployment: ## Run comprehensive deployment tests
	bash $(SCRIPTS_DIR)/test-deployment.sh

.PHONY: clean
clean: ## Clean up everything
	kubectl delete namespace $(ENVIRONMENT) --ignore-not-found=true
	kubectl delete namespace monitoring --ignore-not-found=true
	cd $(TERRAFORM_DIR) && terraform destroy -auto-approve
	rm -rf kubernetes/rendered/
	@echo "✓ Cleanup completed"

# Development helpers
.PHONY: port-forward-python
port-forward-python: ## Port forward Python service to localhost:5000
	kubectl -n $(ENVIRONMENT) port-forward service/python-service-service 5000:5000

.PHONY: port-forward-nodejs
port-forward-nodejs: ## Port forward Node.js service to localhost:3000
	kubectl -n $(ENVIRONMENT) port-forward service/nodejs-service-service 3000:3000

.PHONY: port-forward-postgres
port-forward-postgres: ## Port forward PostgreSQL to localhost:5432
	kubectl -n $(ENVIRONMENT) port-forward service/postgres-service 5432:5432

.PHONY: port-forward-grafana
port-forward-grafana: ## Port forward Grafana to localhost:3001
	kubectl -n monitoring port-forward service/prometheus-grafana 3001:80

# Troubleshooting
.PHONY: describe-pods
describe-pods: ## Describe all pods in namespace
	kubectl -n $(ENVIRONMENT) describe pods

.PHONY: events
events: ## Show recent events in namespace
	kubectl -n $(ENVIRONMENT) get events --sort-by='.lastTimestamp'

.PHONY: exec-python
exec-python: ## Execute shell in Python service pod
	kubectl -n $(ENVIRONMENT) exec -it $$(kubectl -n $(ENVIRONMENT) get pod -l app=python-service -o jsonpath='{.items[0].metadata.name}') -- /bin/sh

.PHONY: exec-nodejs
exec-nodejs: ## Execute shell in Node.js service pod
	kubectl -n $(ENVIRONMENT) exec -it $$(kubectl -n $(ENVIRONMENT) get pod -l app=nodejs-service -o jsonpath='{.items[0].metadata.name}') -- /bin/sh

.PHONY: exec-postgres
exec-postgres: ## Execute shell in PostgreSQL pod
	kubectl -n $(ENVIRONMENT) exec -it postgres-0 -- /bin/bash
