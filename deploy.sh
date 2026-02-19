#!/bin/bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
ACR_NAME="hotelragpipeline"
IMAGE_NAME="hotel-rag"
IMAGE_TAG="latest"
RESOURCE_GROUP="rg-rag-pipeline"
CONTAINER_NAME="hotel-rag"
STORAGE_ACCOUNT="hoteltrainingstorage"
SHARE_NAME="chroma-data"
MOUNT_PATH="/app/chroma"
# ──────────────────────────────────────────────────────────────────────────────

FULL_IMAGE="${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"

# Validate required env vars
: "${AZURE_FOUNDRY_ENDPOINT:?AZURE_FOUNDRY_ENDPOINT is not set}"
: "${AZURE_FOUNDRY_KEY:?AZURE_FOUNDRY_KEY is not set}"

echo "==> Logging in to ACR: ${ACR_NAME}"
az acr login --name "${ACR_NAME}"

echo "==> Building image: ${FULL_IMAGE}"
docker build -t "${FULL_IMAGE}" .

echo "==> Pushing image: ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

echo "==> Fetching storage account key"
STORAGE_KEY=$(az storage account keys list \
  --resource-group "${RESOURCE_GROUP}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --query "[0].value" -o tsv)

echo "==> Deploying container: ${CONTAINER_NAME}"
az container create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CONTAINER_NAME}" \
  --image "${FULL_IMAGE}" \
  --os-type Linux \
  --ip-address Public \
  --cpu 1 --memory 2 \
  --ports 8000 \
  --registry-login-server "${ACR_NAME}.azurecr.io" \
  --registry-username "$(az acr credential show --name "${ACR_NAME}" --query username -o tsv)" \
  --registry-password "$(az acr credential show --name "${ACR_NAME}" --query passwords[0].value -o tsv)" \
  --environment-variables \
    AZURE_FOUNDRY_ENDPOINT="${AZURE_FOUNDRY_ENDPOINT}" \
    AZURE_FOUNDRY_KEY="${AZURE_FOUNDRY_KEY}" \
  --azure-file-volume-account-name "${STORAGE_ACCOUNT}" \
  --azure-file-volume-account-key "${STORAGE_KEY}" \
  --azure-file-volume-share-name "${SHARE_NAME}" \
  --azure-file-volume-mount-path "${MOUNT_PATH}"

echo "==> Done. Container '${CONTAINER_NAME}' deployed."
