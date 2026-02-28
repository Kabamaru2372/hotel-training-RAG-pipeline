terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  resource_provider_registrations = "none"
}


resource "azurerm_resource_group" "rg_rag_pipeline" {
  name     = "rg-rag-pipeline"
  location = "westeurope"
}

resource "azurerm_storage_account" "main" {
  name                     = "hoteltrainingstorage"
  resource_group_name      = azurerm_resource_group.rg_rag_pipeline.name
  location                 = azurerm_resource_group.rg_rag_pipeline.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_search_service" "search" {
  name                = "srch-rag-demo-001"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  sku                 = "basic" # 'basic' or 'standard' is required for RAG; 'free' has limits

  # Enables the "Add Your Data" feature to work via Managed Identity
  identity {
    type = "SystemAssigned"
  }

  # Required for the "One-Click" UI to display citations correctly
  semantic_search_sku = "free"
}

# Permissions: Allow AI Search to read your Blobs
resource "azurerm_role_assignment" "search_to_storage" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_search_service.search.identity[0].principal_id
}

resource "null_resource" "search_datasource" {
  triggers = {
    storage_account_id = azurerm_storage_account.main.id
    search_service_id  = azurerm_search_service.search.id
  }

  provisioner "local-exec" {
    environment = {
      SEARCH_URL = "https://${azurerm_search_service.search.name}.search.windows.net"
      SEARCH_KEY = azurerm_search_service.search.primary_key
      STORAGE_ID = azurerm_storage_account.main.id
    }
    command = <<-EOT
      curl -sf -X PUT \
        "$SEARCH_URL/datasources/blob-datasource?api-version=2024-07-01" \
        -H "Content-Type: application/json" \
        -H "api-key: $SEARCH_KEY" \
        -d "{\"type\":\"azureblob\",\"name\":\"blob-datasource\",\"container\":{\"name\":\"hotel-data\"},\"description\":\"Connection to my RAG docs\",\"credentials\":{\"connectionString\":\"ResourceId=$STORAGE_ID\"}}"
    EOT
  }
}

resource "null_resource" "search_index" {
  triggers = {
    search_service_id = azurerm_search_service.search.id
  }

  provisioner "local-exec" {
    environment = {
      SEARCH_URL = "https://${azurerm_search_service.search.name}.search.windows.net"
      SEARCH_KEY = azurerm_search_service.search.primary_key
    }
    command = <<-EOT
      curl -sf -X PUT \
        "$SEARCH_URL/indexes/rag-index?api-version=2024-07-01" \
        -H "Content-Type: application/json" \
        -H "api-key: $SEARCH_KEY" \
        -d "{\"name\":\"rag-index\",\"fields\":[{\"name\":\"id\",\"type\":\"Edm.String\",\"key\":true,\"searchable\":false},{\"name\":\"content\",\"type\":\"Edm.String\",\"searchable\":true,\"retrievable\":true},{\"name\":\"metadata_storage_name\",\"type\":\"Edm.String\",\"searchable\":true,\"retrievable\":true}]}"
    EOT
  }
}

resource "null_resource" "search_indexer" {
  triggers = {
    datasource_trigger = null_resource.search_datasource.id
    index_trigger      = null_resource.search_index.id
  }

  provisioner "local-exec" {
    environment = {
      SEARCH_URL = "https://${azurerm_search_service.search.name}.search.windows.net"
      SEARCH_KEY = azurerm_search_service.search.primary_key
    }
    command = <<-EOT
      curl -sf -X PUT \
        "$SEARCH_URL/indexers/blob-indexer?api-version=2024-07-01" \
        -H "Content-Type: application/json" \
        -H "api-key: $SEARCH_KEY" \
        -d "{\"name\":\"blob-indexer\",\"dataSourceName\":\"blob-datasource\",\"targetIndexName\":\"rag-index\",\"schedule\":{\"interval\":\"PT1H\"},\"parameters\":{\"configuration\":{\"indexedFileNameExtensions\":\".pdf,.docx,.txt,.md\",\"parsingMode\":\"default\"}}}"
    EOT
  }

  depends_on = [
    null_resource.search_datasource,
    null_resource.search_index
  ]
}

resource "azurerm_storage_share" "chroma_share" {
  name               = "chroma-data"
  storage_account_id = azurerm_storage_account.main.id
  quota              = 5 # Size in GB
}

resource "azurerm_storage_container" "uploads" {
  name               = "hotel-data"
  storage_account_id = azurerm_storage_account.main.id
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "storage_account_key" {
  value     = azurerm_storage_account.main.primary_access_key
  sensitive = true
}

resource "azurerm_cognitive_account" "openai" {
  name                = "hotel-openai"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  kind                = "OpenAI"
  sku_name            = "S0"

  identity {
    type = "SystemAssigned"
  }
}

# Allow Azure OpenAI to query the search index using its managed identity
resource "azurerm_role_assignment" "openai_to_search" {
  scope                = azurerm_search_service.search.id
  role_definition_name = "Search Index Data Reader"
  principal_id         = azurerm_cognitive_account.openai.identity[0].principal_id
}

# Allow Azure OpenAI to read source documents from blob storage
resource "azurerm_role_assignment" "openai_to_storage" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_cognitive_account.openai.identity[0].principal_id
}


output "azure_openai_endpoint" {
  value = azurerm_cognitive_account.openai.endpoint
}

output "azure_openai_key" {
  value     = azurerm_cognitive_account.openai.primary_access_key
  sensitive = true
}

resource "azurerm_container_registry" "acr" {
  name                = "hotelragpipeline"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  sku                 = "Basic"
  admin_enabled       = true
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = "gpt-4o"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4o"
    version = "2024-11-20"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 10
  }
}

resource "azurerm_cognitive_deployment" "embedding" {
  name                 = "text-embedding-3-small"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "text-embedding-3-small"
    version = "1"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 10
  }
}

# ── Application Insights ─────────────────────────────────────────────────────

resource "azurerm_log_analytics_workspace" "main" {
  name                = "hotel-rag-logs"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "main" {
  name                = "hotel-rag-insights"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
}

# ── Azure Function (Event Grid trigger) ─────────────────────────────────────

variable "rag_app_url" {
  description = "URL of the deployed RAG app (e.g. https://<container-app>.azurecontainerapps.io)"
  type        = string
  default     = "http://localhost:8000"
}

# Separate storage account required by the Functions runtime
resource "azurerm_storage_account" "func_storage" {
  name                     = "hotelragfuncstorage"
  resource_group_name      = azurerm_resource_group.rg_rag_pipeline.name
  location                 = azurerm_resource_group.rg_rag_pipeline.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Serverless consumption plan
resource "azurerm_service_plan" "func_plan" {
  name                = "hotel-rag-func-plan"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_linux_function_app" "trigger" {
  name                       = "hotel-rag-trigger"
  resource_group_name        = azurerm_resource_group.rg_rag_pipeline.name
  location                   = azurerm_resource_group.rg_rag_pipeline.location
  storage_account_name       = azurerm_storage_account.func_storage.name
  storage_account_access_key = azurerm_storage_account.func_storage.primary_access_key
  service_plan_id            = azurerm_service_plan.func_plan.id

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME              = "python"
    STORAGE_CONN_STR                      = azurerm_storage_account.main.primary_connection_string
    RAG_APP_URL                           = var.rag_app_url
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.main.connection_string
  }
}

output "function_app_name" {
  value = azurerm_linux_function_app.trigger.name
}

output "rag_app_url" {
  value = var.rag_app_url
}

# ── Chat Web App (microsoft/sample-app-aoai-chatgpt frontend) ────────────────

resource "azurerm_service_plan" "chat_plan" {
  name                = "hotel-chat-plan"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "chat" {
  name                = "hotel-ai"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  service_plan_id     = azurerm_service_plan.chat_plan.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
    # Default startup command for the sample Flask app
    app_command_line = "gunicorn --bind=0.0.0.0 --timeout 600 app:app"
  }

  auth_settings_v2 {
    auth_enabled           = true
    require_authentication = true
    unauthenticated_action = "RedirectToLoginPage"
    default_provider       = "azureactivedirectory"
    require_https          = true

    active_directory_v2 {
      client_id            = "55488ec3-1a1e-4324-b046-571a96f125f1"
      client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
      tenant_auth_endpoint = "https://sts.windows.net/820cb8a9-42f5-4642-913a-8a00678c4c66/v2.0"
      allowed_audiences    = ["api://55488ec3-1a1e-4324-b046-571a96f125f1"]
      allowed_applications = ["55488ec3-1a1e-4324-b046-571a96f125f1"]
    }

    login {
      token_store_enabled = true
    }
  }

  app_settings = {
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"

    # ── Azure OpenAI ───────────────────────────────────────────────────────────
    AZURE_OPENAI_RESOURCE       = azurerm_cognitive_account.openai.name
    AZURE_OPENAI_ENDPOINT       = azurerm_cognitive_account.openai.endpoint
    AZURE_OPENAI_KEY            = azurerm_cognitive_account.openai.primary_access_key
    AZURE_OPENAI_MODEL          = azurerm_cognitive_deployment.gpt4o.name
    AZURE_OPENAI_MODEL_NAME     = azurerm_cognitive_deployment.gpt4o.name
    AZURE_OPENAI_TEMPERATURE    = "0.7"
    AZURE_OPENAI_TOP_P          = "0.95"
    AZURE_OPENAI_MAX_TOKENS     = "2000"
    AZURE_OPENAI_SYSTEM_MESSAGE = "You are an AI assistant that helps hotel staff find information. Only answer questions using the provided documents. If the answer is not found in the documents, say you don't have that information. Do not make up or infer answers beyond what the documents contain."

    # ── Azure AI Search ────────────────────────────────────────────────────────
    # query_type=simple: our index has no semantic configuration, so semantic
    # search must be off — using it causes a 400 from the OpenAI On Your Data API.
    DATASOURCE_TYPE                  = "AzureCognitiveSearch"
    AZURE_SEARCH_SERVICE             = azurerm_search_service.search.name
    AZURE_SEARCH_KEY                 = azurerm_search_service.search.primary_key
    AZURE_SEARCH_INDEX               = "rag-index"
    AZURE_SEARCH_CONTENT_COLUMNS     = "content"
    AZURE_SEARCH_FILENAME_COLUMN     = "metadata_storage_name"
    AZURE_SEARCH_QUERY_TYPE          = "simple"
    AZURE_SEARCH_USE_SEMANTIC_SEARCH = "false"
    AZURE_SEARCH_TOP_K               = "5"
    AZURE_SEARCH_STRICTNESS          = "5"
    AZURE_SEARCH_ENABLE_IN_DOMAIN    = "true"
  }

  depends_on = [
    null_resource.search_index,
    azurerm_role_assignment.openai_to_search,
    azurerm_role_assignment.openai_to_storage,
  ]
}

resource "azurerm_role_assignment" "chat_to_openai" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_linux_web_app.chat.identity[0].principal_id
}

resource "azurerm_role_assignment" "chat_to_search" {
  scope                = azurerm_search_service.search.id
  role_definition_name = "Search Index Data Reader"
  principal_id         = azurerm_linux_web_app.chat.identity[0].principal_id
}

# Deploy the sample app code from GitHub.
# Clones microsoft/sample-app-aoai-chatgpt, zips it, and pushes via Kudu.
# Re-runs whenever the web app resource is recreated.
resource "null_resource" "chat_app_code" {
  triggers = {
    webapp_id = azurerm_linux_web_app.chat.id
  }

  provisioner "local-exec" {
    environment = {
      RESOURCE_GROUP = azurerm_resource_group.rg_rag_pipeline.name
      WEBAPP_NAME    = azurerm_linux_web_app.chat.name
    }
    command = <<-EOT
      TMPDIR=$(mktemp -d)
      git clone --depth 1 https://github.com/microsoft/sample-app-aoai-chatgpt "$TMPDIR/app" 2>&1
      cd "$TMPDIR/app"
      zip -r "$TMPDIR/deploy.zip" . -x ".git/*" > /dev/null
      az webapp deploy \
        --resource-group "$RESOURCE_GROUP" \
        --name "$WEBAPP_NAME" \
        --src-path "$TMPDIR/deploy.zip" \
        --type zip \
        --timeout 600
      rm -rf "$TMPDIR"
    EOT
  }

  depends_on = [azurerm_linux_web_app.chat]
}

output "chat_webapp_name" {
  value = azurerm_linux_web_app.chat.name
}

output "chat_webapp_url" {
  value = "https://${azurerm_linux_web_app.chat.default_hostname}"
}

