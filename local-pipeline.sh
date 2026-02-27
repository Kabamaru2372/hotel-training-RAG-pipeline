#!/bin/bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
RESOURCE_GROUP="rg-rag-pipeline"
CONTAINER_NAME="hotel-rag"
WEBAPP_NAME="hotel-ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ──────────────────────────────────────────────────────────────────────────────

# ── Step 1: Initialise and provision core infrastructure ──────────────────────
echo "==> Step 1: Provisioning infrastructure (first pass)"

# Init is safe to run on every invocation; -upgrade picks up provider changes.
terraform -chdir="${SCRIPT_DIR}/terraform" init -upgrade -input=false

# The first pass creates everything except the chat web app code deployment
# and the Function App's rag_app_url (container doesn't exist yet).
# If hotel-ai already exists outside Terraform state (e.g. from a previous
# Foundry Studio deploy), import it so Terraform adopts it instead of failing.
if az webapp show \
    --name "${WEBAPP_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --output none 2>/dev/null; then
  if ! terraform -chdir="${SCRIPT_DIR}/terraform" state list \
      | grep -q "azurerm_linux_web_app.chat"; then
    echo "    Importing existing '${WEBAPP_NAME}' web app into Terraform state..."
    WEBAPP_ID=$(az webapp show \
      --name "${WEBAPP_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --query id -o tsv)
    terraform -chdir="${SCRIPT_DIR}/terraform" import \
      azurerm_linux_web_app.chat "${WEBAPP_ID}"
    # Also import the service plan if it exists
    PLAN_ID=$(az appservice plan show \
      --name "hotel-chat-plan" \
      --resource-group "${RESOURCE_GROUP}" \
      --query id -o tsv 2>/dev/null || true)
    if [ -n "${PLAN_ID:-}" ]; then
      terraform -chdir="${SCRIPT_DIR}/terraform" import \
        azurerm_service_plan.chat_plan "${PLAN_ID}" 2>/dev/null || true
    fi
  fi
fi

terraform -chdir="${SCRIPT_DIR}/terraform" apply -auto-approve

# ── Step 2: Build and deploy the RAG backend container ───────────────────────
echo "==> Step 2: Build and deploy RAG container"
"${SCRIPT_DIR}/deploy.sh"

# ── Step 3: Fetch the container's public IP ───────────────────────────────────
echo "==> Step 3: Fetching container IP"
CONTAINER_IP=$(az container show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CONTAINER_NAME}" \
  --query ipAddress.ip -o tsv)
echo "    Container IP: ${CONTAINER_IP}"

# ── Step 4: Wire the container URL into all dependent resources ───────────────
echo "==> Step 4: Updating Terraform with rag_app_url=http://${CONTAINER_IP}:8000"
# This pass updates the Function App's RAG_APP_URL and, if the chat web app
# was just created, triggers the null_resource that deploys the sample app code.
terraform -chdir="${SCRIPT_DIR}/terraform" apply -auto-approve \
  -var "rag_app_url=http://${CONTAINER_IP}:8000"

# ── Step 5: Publish the Azure Function ───────────────────────────────────────
FUNCTION_APP_NAME=$(terraform -chdir="${SCRIPT_DIR}/terraform" output -raw function_app_name)
echo "==> Step 5: Publishing Azure Function to ${FUNCTION_APP_NAME}"
(cd "${SCRIPT_DIR}/function_app" && func azure functionapp publish "${FUNCTION_APP_NAME}" --python)

# ── Done ──────────────────────────────────────────────────────────────────────
CHAT_URL=$(terraform -chdir="${SCRIPT_DIR}/terraform" output -raw chat_webapp_url)

echo ""
echo "============================================================"
echo " Deployment complete"
echo "============================================================"
echo " RAG backend : http://${CONTAINER_IP}:8000"
echo " Chat web app: ${CHAT_URL}"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  Upload training data:  ./upload.sh"
echo "  Trigger indexer now:   az search indexer run --service-name srch-rag-demo-001 --name blob-indexer --resource-group ${RESOURCE_GROUP}"
