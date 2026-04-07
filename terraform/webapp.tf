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
      client_id                  = "55488ec3-1a1e-4324-b046-571a96f125f1"
      client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
      tenant_auth_endpoint       = "https://sts.windows.net/820cb8a9-42f5-4642-913a-8a00678c4c66/v2.0"
      allowed_audiences          = ["api://55488ec3-1a1e-4324-b046-571a96f125f1"]
      allowed_applications       = ["55488ec3-1a1e-4324-b046-571a96f125f1"]
    }

    login {
      token_store_enabled = true
    }
  }

  app_settings = {
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"

    # ── Azure OpenAI ───────────────────────────────────────────────────────────
    AZURE_OPENAI_RESOURCE       = azurerm_cognitive_account.openai.custom_subdomain_name
    AZURE_OPENAI_ENDPOINT       = azurerm_cognitive_account.openai.endpoint
    AZURE_OPENAI_KEY            = azurerm_cognitive_account.openai.primary_access_key
    AZURE_OPENAI_MODEL          = azurerm_cognitive_deployment.gpt4o.name
    AZURE_OPENAI_MODEL_NAME     = azurerm_cognitive_deployment.gpt4o.name
    AZURE_OPENAI_TEMPERATURE    = "0.7"
    AZURE_OPENAI_TOP_P          = "0.95"
    AZURE_OPENAI_MAX_TOKENS     = "2000"
    AZURE_OPENAI_SYSTEM_MESSAGE = "You are an AI assistant that helps hotel staff find information. Answer questions based on the provided documents. You may reason, compare, and calculate using data found in the documents. If the documents do not contain relevant information at all, say you don't have that information. Do not fabricate facts that have no basis in the documents."

    # ── Azure AI Search ────────────────────────────────────────────────────────
    DATASOURCE_TYPE                       = "AzureCognitiveSearch"
    AZURE_SEARCH_SERVICE                  = azurerm_search_service.search.name
    AZURE_SEARCH_KEY                      = azurerm_search_service.search.primary_key
    AZURE_SEARCH_INDEX                    = "rag-index"
    AZURE_SEARCH_CONTENT_COLUMNS          = "content"
    AZURE_SEARCH_FILENAME_COLUMN          = "metadata_storage_name"
    AZURE_SEARCH_QUERY_TYPE               = "semantic"
    AZURE_SEARCH_USE_SEMANTIC_SEARCH      = "true"
    AZURE_SEARCH_SEMANTIC_SEARCH_CONFIG   = "rag-semantic-config"
    AZURE_SEARCH_TOP_K                    = "5"
    AZURE_SEARCH_STRICTNESS               = "2"
    AZURE_SEARCH_ENABLE_IN_DOMAIN         = "false"
  }

  depends_on = [
    null_resource.search_index,
    azurerm_role_assignment.openai_to_search,
    azurerm_role_assignment.openai_to_storage,
  ]
}

# Allow the web app to call Azure OpenAI
resource "azurerm_role_assignment" "chat_to_openai" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_linux_web_app.chat.identity[0].principal_id
}

# Allow the web app to query the search index
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
