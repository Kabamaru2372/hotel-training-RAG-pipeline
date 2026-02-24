# Hotel Training RAG Pipeline

A Retrieval-Augmented Generation (RAG) pipeline for hotel training documents. Uploads training data to Azure Blob Storage, processes it via an Azure Function trigger, and serves queries through a containerised FastAPI app backed by ChromaDB and Azure OpenAI.

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| [Docker](https://docs.docker.com/get-docker/) | Build and push the app image |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) | Interact with Azure resources |
| [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.1 | Provision infrastructure |

Log in to Azure before running any script:

```bash
az login
```

---

## 1. Build and Push the Docker Image

The `deploy.sh` script handles the full build-and-push cycle and deploys the container to Azure Container Instances. Run it from the repository root:

```bash
./deploy.sh
```

**What it does, step by step:**

1. Reads `azure_openai_endpoint` and `azure_openai_key` from Terraform outputs.
2. Logs in to the Azure Container Registry (`hotelragpipeline.azurecr.io`).
3. Builds the image from the local `Dockerfile` and tags it `hotelragpipeline.azurecr.io/hotel-rag:latest`.
4. Pushes the image to ACR.
5. Retrieves the storage account key for the Azure Files share used to persist ChromaDB data.
6. Creates (or recreates) an Azure Container Instance named `hotel-rag` with:
   - 1 vCPU / 2 GB RAM, port 8000 exposed publicly.
   - The OpenAI endpoint and key injected as environment variables.
   - The `chroma-data` Azure Files share mounted at `/app/chroma` so the vector database survives restarts.
7. Prints the container's public IP address.

**To build and push manually** (without deploying to ACI):

```bash
# Log in to ACR
az acr login --name hotelragpipeline

# Build
docker build -t hotelragpipeline.azurecr.io/hotel-rag:latest .

# Push
docker push hotelragpipeline.azurecr.io/hotel-rag:latest
```

### Dockerfile overview

```
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
VOLUME ["/app/chroma"]           # ChromaDB persistence mount point
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```

---

## 2. Provision Infrastructure with Terraform (`local-pipeline.sh`)

`local-pipeline.sh` is the end-to-end local deployment script. It calls `deploy.sh` first and then runs `terraform apply` with the deployed container's IP.

```bash
./local-pipeline.sh
```

**What it does, step by step:**

1. **Step 1 – Provision infrastructure**: runs `terraform apply -auto-approve` inside `terraform/` to create all Azure resources (ACR, storage, OpenAI, Function App, etc.).
2. **Step 2 – Build and deploy container**: calls `deploy.sh`, which reads the Terraform outputs for the OpenAI credentials, builds and pushes the image, and deploys the ACI container.
3. **Step 3 – Fetch container IP**: queries ACI for the public IP of the running `hotel-rag` container.
4. **Step 4 – Update Terraform with container URL**: re-runs `terraform apply -auto-approve` passing the real container IP so the Azure Function App is configured with the correct `rag_app_url`.

```
terraform apply -var "rag_app_url=http://<container-ip>:8000"
```

### Running Terraform independently

If infrastructure is already provisioned and you only need to update it:

```bash
cd terraform

# First-time only
terraform init

# Preview changes
terraform plan -var "rag_app_url=http://<container-ip>:8000"

# Apply
terraform apply -var "rag_app_url=http://<container-ip>:8000"
```

### What Terraform provisions

| Resource | Name |
|----------|------|
| Resource Group | `rg-rag-pipeline` (West Europe) |
| Storage Account (data) | `hoteltrainingstorage` |
| Blob Container | `hotel-data` |
| Azure OpenAI | `hotel-openai` with `gpt-4o` and `text-embedding-3-small` deployments |
| Container Registry | `hotelragpipeline` (Basic, admin enabled) |
| Log Analytics Workspace | `hotel-rag-logs` |
| Application Insights | `hotel-rag-insights` |
| Function App Storage | `hotelragfuncstorage` |
| Linux Function App | `hotel-rag-trigger` (Python 3.11, consumption plan) |

---

## 3. Uploading Training Data (`upload.sh`)

`upload.sh` uploads Markdown training files from the local `./data/` directory to the `hotel-data` blob container in Azure Storage.

### Usage

```bash
# Upload all files in ./data/
./upload.sh

# Upload a single file from ./data/
./upload.sh 01-checkin-checkout-procedures.md
```

**What it does:**

1. Fetches the storage account key for `hoteltrainingstorage` via the Azure CLI.
2. For each file to upload, checks whether a blob with that name already exists in the `hotel-data` container.
3. If the blob **does not exist**, uploads it immediately.
4. If the blob **already exists**, prompts for confirmation before overwriting:
   ```
   ==> 'filename.md' already exists. Overwrite? [y/N]
   ```
   - Enter `y` to overwrite, any other input skips the file.
5. Prints a status line for every file processed.

### Adding new training documents

1. Place the file inside the `./data/` directory.
2. Run `./upload.sh <filename>` or `./upload.sh` to upload everything.
3. The Azure Function (`hotel-rag-trigger`) is triggered by blob creation events and forwards the content to the RAG app for ingestion into ChromaDB.
