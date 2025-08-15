#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Testing Deployment ===${NC}"

MINIKUBE_IP=$(minikube ip)

# Test Python Service
echo -e "\n${YELLOW}Testing Python Service...${NC}"
PYTHON_RESPONSE=$(curl -s http://$MINIKUBE_IP:30001/health)
if echo $PYTHON_RESPONSE | grep -q "healthy"; then
    echo -e "${GREEN}✓ Python service is healthy${NC}"
    echo $PYTHON_RESPONSE | jq .
else
    echo -e "${RED}✗ Python service health check failed${NC}"
fi

# Test Node.js Service
echo -e "\n${YELLOW}Testing Node.js Service...${NC}"
NODE_RESPONSE=$(curl -s http://$MINIKUBE_IP:30002/status)
if echo $NODE_RESPONSE | grep -q "ok"; then
    echo -e "${GREEN}✓ Node.js service is healthy${NC}"
    echo $NODE_RESPONSE | jq .
else
    echo -e "${RED}✗ Node.js service status check failed${NC}"
fi

# Test Database Connectivity
echo -e "\n${YELLOW}Testing Database Connectivity...${NC}"
kubectl -n dev exec -it postgres-0 -- psql -U admin -d microservices -c "SELECT 1;" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ PostgreSQL is accessible${NC}"
else
    echo -e "${RED}✗ PostgreSQL connection failed${NC}"
fi

# Test Metrics Endpoints
echo -e "\n${YELLOW}Testing Metrics Endpoints...${NC}"
PYTHON_METRICS=$(curl -s http://$MINIKUBE_IP:30001/metrics | head -5)
NODE_METRICS=$(curl -s http://$MINIKUBE_IP:30002/metrics | head -5)

if [ ! -z "$PYTHON_METRICS" ]; then
    echo -e "${GREEN}✓ Python metrics endpoint working${NC}"
else
    echo -e "${RED}✗ Python metrics endpoint failed${NC}"
fi

if [ ! -z "$NODE_METRICS" ]; then
    echo -e "${GREEN}✓ Node.js metrics endpoint working${NC}"
else
    echo -e "${RED}✗ Node.js metrics endpoint failed${NC}"
fi

# Check Grafana
echo -e "\n${YELLOW}Testing Grafana...${NC}"
GRAFANA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$MINIKUBE_IP:30900)
if [ $GRAFANA_STATUS -eq 200 ]; then
    echo -e "${GREEN}✓ Grafana is accessible at http://$MINIKUBE_IP:30900${NC}"
else
    echo -e "${RED}✗ Grafana is not accessible${NC}"
fi

echo -e "\n${GREEN}=== Testing Complete ===${NC}"