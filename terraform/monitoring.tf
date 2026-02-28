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
