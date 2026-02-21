#!/bin/bash
set -euo pipefail

RESOURCE_GROUP="rg-rag-pipeline"
CONTAINER_NAME="hotel-rag"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Step 1: Build and deploy container"
"${SCRIPT_DIR}/deploy.sh"

echo "==> Step 2: Fetching container IP"
CONTAINER_IP=$(az container show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CONTAINER_NAME}" \
  --query ipAddress.ip -o tsv)

echo "==> Container IP: ${CONTAINER_IP}"

echo "==> Step 3: Running terraform apply with rag_app_url=http://${CONTAINER_IP}:8000"
terraform -chdir="${SCRIPT_DIR}/terraform" apply -auto-approve \
  -var "rag_app_url=http://${CONTAINER_IP}:8000"
