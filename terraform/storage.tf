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

resource "azurerm_storage_share" "chroma_share" {
  name               = "chroma-data"
  storage_account_id = azurerm_storage_account.main.id
  quota              = 5 # Size in GB
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "storage_account_key" {
  value     = azurerm_storage_account.main.primary_access_key
  sensitive = true
}
