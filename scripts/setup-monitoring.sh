#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Setting up Monitoring Stack ===${NC}"

# Create monitoring namespace if not exists
if ! kubectl get namespace monitoring &> /dev/null; then
    echo -e "${YELLOW}Creating monitoring namespace...${NC}"
    kubectl create namespace monitoring
fi

# Add Prometheus Helm repository
echo -e "${YELLOW}Adding Prometheus Helm repository...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack
echo -e "${YELLOW}Installing Prometheus and Grafana...${NC}"
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set grafana.enabled=true \
    --set grafana.adminPassword=admin123 \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort=30900 \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --wait

# Create ServiceMonitors for our services
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: python-service-monitor
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
    - dev
    - staging
    - prod
  selector:
    matchLabels:
      app: python-service
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nodejs-service-monitor
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
    - dev
    - staging
    - prod
  selector:
    matchLabels:
      app: nodejs-service
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
EOF

echo -e "${GREEN}✓ Monitoring stack setup complete${NC}"
echo ""
echo -e "${YELLOW}Grafana Access:${NC}"
echo "  URL: http://$(minikube ip):30900"
echo "  Username: admin"
echo "  Password: admin123"