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
