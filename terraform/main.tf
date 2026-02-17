terraform {
   required_providers {
     azurerm = {
       source  = "hashicorp/azurerm"
       version = "~> 3.0"
     }
   }
   required_version = ">= 1.1.0"
 }

 provider "azurerm" {
   features {}
 }

 # Create a Resource Group
 resource "azurerm_resource_group" "rg_rag_pipeline" {
   name     = "rg-rag-pipeline"
   location = "westeurope"
 }

resource "azurerm_storage_account" "main" {
  name                     = "hotel-training-storage"
  resource_group_name      = azurerm_resource_group.rg_rag_pipeline.name
  location                 = azurerm_resource_group.rg_rag_pipeline.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "uploads" {
  name                 = "hotel-data"
  storage_account_name = azurerm_storage_account.rg_rag_pipeline.name
}

resource "azurerm_cognitive_account" "openai" {
  name                = "hotel-openai"
  resource_group_name = azurerm_resource_group.rg_rag_pipeline.name
  location            = azurerm_resource_group.rg_rag_pipeline.location
  kind                = "OpenAI"
  sku_name            = "S0"
}
