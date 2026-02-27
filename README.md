# Hotel Training RAG Pipeline

A Retrieval-Augmented Generation (RAG) pipeline for hotel training documents.
Staff upload Markdown/PDF training files to Azure Blob Storage; an Azure Function
ingests them into a ChromaDB vector store; a FastAPI backend serves semantic
queries; and a hosted chat web app provides a conversational interface over the
documents.

```
 ./data/  ──upload.sh──►  Blob Storage  ──Function──►  RAG backend (ACI)
                                │                           │
                          AI Search index  ◄───────────────┘
                                │
                          Chat web app  ◄──── users
```

---

## Prerequisites

| Tool | Min version | Purpose |
|------|-------------|---------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) | any | Manage Azure resources |
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.1 | Provision infrastructure |
| [Docker](https://docs.docker.com/get-docker/) | any | Build the RAG container |
| [Azure Functions Core Tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local) (`func`) | v4 | Publish the Function App |
| `git` | any | Clone the chat frontend during deploy |
| `zip` | any | Package the chat frontend during deploy |

Log in to Azure before running anything:

```bash
az login
```

---

## From-scratch deployment

Everything is driven by a single script:

```bash
./local-pipeline.sh
```

That's it. The script is safe to re-run — Terraform is idempotent and the
container/function deploys are replaced in-place.

### What the script does

| Step | What happens |
|------|-------------|
| **1 – Provision (first pass)** | `terraform init` + `terraform apply` creates all Azure resources. If the `hotel-ai` web app already exists outside Terraform (e.g. a previous Foundry Studio deploy), it is automatically imported so Terraform adopts it. |
| **2 – Build & deploy container** | `deploy.sh` builds the Docker image, pushes it to ACR, and creates the ACI container. |
| **3 – Get container IP** | Queries ACI for the public IP of the running `hotel-rag` container. |
| **4 – Provision (second pass)** | Re-runs `terraform apply -var "rag_app_url=http://<ip>:8000"` — this wires the real container URL into the Function App and triggers the chat web app code deployment. |
| **5 – Publish Function** | `func azure functionapp publish` pushes the local `function_app/` code to `hotel-rag-trigger`. |

At the end the script prints the RAG backend URL and the chat web app URL.

---

## What Terraform creates

### Infrastructure

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | `rg-rag-pipeline` | West Europe |
| Storage Account | `hoteltrainingstorage` | Training documents and ChromaDB persistence |
| Blob Container | `hotel-data` | Upload target for training files |
| Azure Files Share | `chroma-data` | Mounted into the ACI container at `/app/chroma` |
| Azure OpenAI | `hotel-openai` | System-assigned managed identity enabled |
| OpenAI deployment | `gpt-4o` | GlobalStandard, 10k TPM |
| OpenAI deployment | `text-embedding-3-small` | GlobalStandard, 10k TPM |
| Container Registry | `hotelragpipeline` | Basic SKU, admin enabled |
| AI Search Service | `srch-rag-demo-001` | Basic SKU, system-assigned identity |
| Log Analytics | `hotel-rag-logs` | 30-day retention |
| Application Insights | `hotel-rag-insights` | Wired to the Function App |
| Function App Storage | `hotelragfuncstorage` | Required by the Functions runtime |
| Function App | `hotel-rag-trigger` | Python 3.11, consumption plan |
| App Service Plan | `hotel-chat-plan` | B1 Linux, for the chat web app |
| Chat Web App | `hotel-ai` | Python 3.11, hosts the chat frontend |

### RBAC role assignments

| Principal | Role | Scope | Purpose |
|-----------|------|-------|---------|
| AI Search managed identity | Storage Blob Data Reader | `hoteltrainingstorage` | Indexer reads blobs |
| Azure OpenAI managed identity | Search Index Data Reader | `srch-rag-demo-001` | Foundry/chat queries the index via managed identity |
| Azure OpenAI managed identity | Storage Blob Data Reader | `hoteltrainingstorage` | Chat frontend can retrieve source documents |

> **Why managed identity on Azure OpenAI?**
> The Foundry Studio chat uses the OpenAI service's system-assigned identity to
> authenticate to AI Search. Without it, the principal ID is unresolvable and
> Azure returns `Resource Id is badly formed or from wrong namespace: NA`.

### Search data plane resources (provisioned via `curl`)

The `azapi` provider cannot authenticate to the AI Search **data plane** with
the ambient Azure AD credential, so these three resources are created with
direct REST calls using the Search admin key:

| Resource | Name |
|----------|------|
| Data source | `blob-datasource` — reads from `hotel-data` container via managed identity |
| Index | `rag-index` — fields: `id`, `content`, `metadata_storage_name` |
| Indexer | `blob-indexer` — runs hourly, indexes `.pdf .docx .txt .md` |

### Chat web app settings

All settings are wired directly from Terraform outputs — no manual
configuration in the portal is needed. Key values:

| Setting | Value |
|---------|-------|
| `AZURE_OPENAI_KEY` | From `azurerm_cognitive_account.openai.primary_access_key` |
| `AZURE_SEARCH_KEY` | From `azurerm_search_service.search.primary_key` |
| `AZURE_SEARCH_QUERY_TYPE` | `simple` |
| `AZURE_SEARCH_CONTENT_COLUMNS` | `content` |
| `AZURE_SEARCH_FILENAME_COLUMN` | `metadata_storage_name` |
| `AZURE_SEARCH_USE_SEMANTIC_SEARCH` | `false` |

> **Why `query_type=simple` and semantic search off?**
> The `rag-index` has no semantic configuration. Sending `query_type=semantic`
> causes Azure OpenAI's On Your Data API to return a 400 Bad Request when it
> tries to forward the semantic search request to AI Search.

---

## Uploading training data

```bash
# Upload every file in ./data/
./upload.sh

# Upload a single file
./upload.sh 01-checkin-checkout-procedures.md
```

`upload.sh` prompts before overwriting an existing blob. After upload the
indexer runs on its hourly schedule. To trigger it immediately:

```bash
az search indexer run \
  --service-name srch-rag-demo-001 \
  --name blob-indexer \
  --resource-group rg-rag-pipeline
```

---

## Running Terraform independently

If infrastructure is already provisioned and you only need to update it:

```bash
cd terraform

# Preview
terraform plan -var "rag_app_url=http://<container-ip>:8000"

# Apply
terraform apply -var "rag_app_url=http://<container-ip>:8000"
```

---

## Tearing everything down

```bash
cd terraform
terraform destroy
```

This deletes the resource group and everything inside it. The next run of
`./local-pipeline.sh` will recreate everything from scratch.

---

## Troubleshooting

### `Error code: 400 — Resource Id is badly formed or from wrong namespace: NA`

**Where:** Foundry Studio chat or the `hotel-ai` web app at query time.

**Cause:** The Azure OpenAI service had no system-assigned managed identity.
When the chat tries to authenticate to AI Search using managed identity, the
principal ID is null — serialised as `NA` — and Azure rejects the resource ID.

**Fix (already applied):** `identity { type = "SystemAssigned" }` is now on
`azurerm_cognitive_account.openai`, and the two RBAC role assignments above
grant it access to the search service and storage account.

---

### `openai.BadRequestError: Error code: 400` in the chat web app logs

**Where:** `hotel-ai` App Service logs, in `send_chat_request`.

**Cause:** Multiple misconfigured app settings:
- `AZURE_OPENAI_KEY` and `AZURE_SEARCH_KEY` were empty (Foundry Studio does not
  populate these when it creates the web app).
- `AZURE_SEARCH_QUERY_TYPE=semantic` with `AZURE_SEARCH_USE_SEMANTIC_SEARCH=true`
  — the index has no semantic configuration, so the On Your Data API rejected
  the request.
- `AZURE_SEARCH_CONTENT_COLUMNS` was empty — the app did not know which index
  field contained the document text.

**Fix (already applied):** All settings are now set directly in
`azurerm_linux_web_app.chat` from Terraform outputs, so they are always correct
on a fresh deploy.

---

### `azapi_data_plane_resource` hangs for 10+ minutes

**Cause:** The `azapi` provider uses Azure AD tokens for data plane access, but
the AI Search data plane requires either an API key or a specific RBAC
configuration that conflicts with the ambient credential.

**Fix (already applied):** The search datasource, index, and indexer are
created with `null_resource` + `curl` using the Search admin key instead.
