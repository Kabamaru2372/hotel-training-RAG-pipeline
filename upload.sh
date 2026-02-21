#!/bin/bash
set -euo pipefail

ACCOUNT_NAME="hoteltrainingstorage"
CONTAINER_NAME="hotel-data"
RESOURCE_GROUP="rg-rag-pipeline"
DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/data"

ACCOUNT_KEY=$(az storage account keys list \
  --resource-group "${RESOURCE_GROUP}" \
  --account-name "${ACCOUNT_NAME}" \
  --query "[0].value" -o tsv)

usage() {
  echo "Usage: $0 [filename]"
  echo "  $0                          # upload all files in ./data"
  echo "  $0 01-checkin-checkout-procedures.md  # upload a single file"
  exit 1
}

upload_file() {
  local file="$1"
  local name
  name="$(basename "$file")"

  local exists
  exists=$(az storage blob exists \
    --account-name "${ACCOUNT_NAME}" \
    --account-key "${ACCOUNT_KEY}" \
    --container-name "${CONTAINER_NAME}" \
    --name "${name}" \
    --query exists -o tsv)

  local overwrite_flag=""
  if [[ "${exists}" == "true" ]]; then
    read -r -p "==> '${name}' already exists. Overwrite? [y/N] " reply
    if [[ "${reply,,}" == "y" ]]; then
      overwrite_flag="--overwrite"
    else
      echo "==> Skipping: ${name}"
      return
    fi
  fi

  echo "==> Uploading: ${name}"
  az storage blob upload \
    --account-name "${ACCOUNT_NAME}" \
    --account-key "${ACCOUNT_KEY}" \
    --container-name "${CONTAINER_NAME}" \
    --file "${file}" \
    --name "${name}" \
    ${overwrite_flag}
}

if [[ $# -eq 0 ]]; then
  echo "==> Uploading all files in ./data"
  for file in "${DATA_DIR}"/*; do
    upload_file "${file}"
  done
  echo "==> Done. All files uploaded."
elif [[ $# -eq 1 ]]; then
  upload_file "${DATA_DIR}/$1"
  echo "==> Done."
else
  usage
fi
