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
   features {}
   resource_provider_registrations = "none"
 }

 # Create a Resource Group
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
    FUNCTIONS_WORKER_RUNTIME = "python"
    STORAGE_CONN_STR         = azurerm_storage_account.main.primary_connection_string
    RAG_APP_URL              = var.rag_app_url
  }
}

output "function_app_name" {
  value = azurerm_linux_function_app.trigger.name
}

