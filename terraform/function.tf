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
