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
        -d "{\"name\":\"rag-index\",\"fields\":[{\"name\":\"id\",\"type\":\"Edm.String\",\"key\":true,\"searchable\":false},{\"name\":\"content\",\"type\":\"Edm.String\",\"searchable\":true,\"retrievable\":true},{\"name\":\"metadata_storage_name\",\"type\":\"Edm.String\",\"searchable\":true,\"retrievable\":true}],\"semantic\":{\"configurations\":[{\"name\":\"rag-semantic-config\",\"prioritizedFields\":{\"prioritizedContentFields\":[{\"fieldName\":\"content\"}],\"prioritizedKeywordsFields\":[],\"titleField\":{\"fieldName\":\"metadata_storage_name\"}}}]}}"
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
