#!/bin/bash
set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
ENVIRONMENT="dev"
DOCKER_USERNAME=""
SKIP_BUILD=false
SKIP_PUSH=false
SKIP_DEPLOY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -u|--username)
            DOCKER_USERNAME="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        --skip-deploy)
            SKIP_DEPLOY=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -e, --environment ENV    Environment (dev|staging|prod) [default: dev]"
            echo "  -u, --username USERNAME  Docker Hub username"
            echo "  --skip-build            Skip building Docker images"
            echo "  --skip-push             Skip pushing Docker images"
            echo "  --skip-deploy           Skip deploying to Kubernetes"
            echo "  -h, --help              Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Check Docker Hub username
if [ -z "$DOCKER_USERNAME" ]; then
    echo -e "${YELLOW}Docker Hub username not provided. Using 'myuser' as default.${NC}"
    DOCKER_USERNAME="myuser"
fi

echo -e "${GREEN}=== Microservices Deployment Script ===${NC}"
echo -e "Environment: ${YELLOW}$ENVIRONMENT${NC}"
echo -e "Docker Username: ${YELLOW}$DOCKER_USERNAME${NC}"
echo ""

# Function to build Docker images
build_images() {
    echo -e "${GREEN}Building Docker images...${NC}"
    
    # Build Python service
    echo -e "${YELLOW}Building Python service...${NC}"
    docker build -t $DOCKER_USERNAME/python-service:latest services/python-service/
    docker tag $DOCKER_USERNAME/python-service:latest $DOCKER_USERNAME/python-service:$ENVIRONMENT
    
    # Build Node.js service
    echo -e "${YELLOW}Building Node.js service...${NC}"
    docker build -t $DOCKER_USERNAME/nodejs-service:latest services/nodejs-service/
    docker tag $DOCKER_USERNAME/nodejs-service:latest $DOCKER_USERNAME/nodejs-service:$ENVIRONMENT
    
    echo -e "${GREEN}✓ Docker images built successfully${NC}"
}

# Function to push Docker images
push_images() {
    echo -e "${GREEN}Pushing Docker images to registry...${NC}"
    
    # Login to Docker Hub
    echo -e "${YELLOW}Please login to Docker Hub:${NC}"
    docker login
    
    # Push Python service
    echo -e "${YELLOW}Pushing Python service...${NC}"
    docker push $DOCKER_USERNAME/python-service:latest
    docker push $DOCKER_USERNAME/python-service:$ENVIRONMENT
    
    # Push Node.js service
    echo -e "${YELLOW}Pushing Node.js service...${NC}"
    docker push $DOCKER_USERNAME/nodejs-service:latest
    docker push $DOCKER_USERNAME/nodejs-service:$ENVIRONMENT
    
    echo -e "${GREEN}✓ Docker images pushed successfully${NC}"
}

# Function to render templates
render_templates() {
    echo -e "${GREEN}Rendering Kubernetes manifests...${NC}"
    
    # Update Docker username in values file
    sed -i.bak "s/YOUR_DOCKERHUB_USERNAME/$DOCKER_USERNAME/g" kubernetes/values/$ENVIRONMENT.yaml
    
    # Render templates
    python3 scripts/render-templates.py --environment $ENVIRONMENT
    
    echo -e "${GREEN}✓ Manifests rendered successfully${NC}"
}

# Function to deploy to Kubernetes
deploy_kubernetes() {
    echo -e "${GREEN}Deploying to Kubernetes...${NC}"
    
    # Check if namespace exists, create if not
    if ! kubectl get namespace $ENVIRONMENT &> /dev/null; then
        echo -e "${YELLOW}Creating namespace: $ENVIRONMENT${NC}"
        kubectl create namespace $ENVIRONMENT
    fi
    
    # Apply manifests
    echo -e "${YELLOW}Applying Kubernetes manifests...${NC}"
    kubectl apply -f kubernetes/rendered/$ENVIRONMENT/
    
    # Wait for deployments to be ready
    echo -e "${YELLOW}Waiting for deployments to be ready...${NC}"
    kubectl -n $ENVIRONMENT wait --for=condition=available --timeout=300s deployment/python-service-deployment
    kubectl -n $ENVIRONMENT wait --for=condition=available --timeout=300s deployment/nodejs-service-deployment
    kubectl -n $ENVIRONMENT wait --for=condition=ready --timeout=300s pod -l app=postgres
    
    echo -e "${GREEN}✓ Deployment completed successfully${NC}"
}

# Function to display access information
display_info() {
    echo -e "${GREEN}=== Deployment Information ===${NC}"
    
    MINIKUBE_IP=$(minikube ip)
    
    echo -e "${YELLOW}Cluster Information:${NC}"
    echo "  Minikube IP: $MINIKUBE_IP"
    echo ""
    
    echo -e "${YELLOW}Service URLs:${NC}"
    echo "  Python Service: http://$MINIKUBE_IP:30001"
    echo "  Node.js Service: http://$MINIKUBE_IP:30002"
    echo "  PostgreSQL: postgresql://$MINIKUBE_IP:30432"
    echo ""
    
    echo -e "${YELLOW}Kubernetes Dashboard:${NC}"
    echo "  Run: minikube dashboard"
    echo ""
    
    if [ "$ENVIRONMENT" = "dev" ]; then
        echo -e "${YELLOW}Grafana Dashboard:${NC}"
        echo "  URL: http://$MINIKUBE_IP:30900"
        echo "  Username: admin"
        echo "  Password: admin123"
    fi
    
    echo ""
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo "  View pods: kubectl -n $ENVIRONMENT get pods"
    echo "  View services: kubectl -n $ENVIRONMENT get services"
    echo "  View logs: kubectl -n $ENVIRONMENT logs -f deployment/[service-name]"
    echo "  Port forward: kubectl -n $ENVIRONMENT port-forward service/[service-name] [local-port]:[service-port]"
}

# Main execution
main() {
    # Check prerequisites
    command -v docker >/dev/null 2>&1 || { echo -e "${RED}Docker is required but not installed.${NC}" >&2; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl is required but not installed.${NC}" >&2; exit 1; }
    command -v minikube >/dev/null 2>&1 || { echo -e "${RED}Minikube is required but not installed.${NC}" >&2; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo -e "${RED}Python 3 is required but not installed.${NC}" >&2; exit 1; }
    
    # Check if Minikube is running
    if ! minikube status | grep -q "Running"; then
        echo -e "${RED}Minikube is not running. Please start it first with Terraform.${NC}"
        exit 1
    fi
    
    # Execute deployment steps
    if [ "$SKIP_BUILD" = false ]; then
        build_images
    fi
    
    if [ "$SKIP_PUSH" = false ]; then
        push_images
    fi
    
    render_templates
    
    if [ "$SKIP_DEPLOY" = false ]; then
        deploy_kubernetes
    fi
    
    display_info
    
    echo -e "${GREEN}=== Deployment Complete ===${NC}"
}

# Run main function
main