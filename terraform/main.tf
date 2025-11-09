terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.113"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  required_version = ">= 1.5.0"
}

provider "azurerm" {
  features {}
}

# === RANDOM SUFFIX ===
resource "random_id" "suffix" {
  byte_length = 4
}

# === 1. RESOURCE GROUP (EXISTING) ===
# Use data source since RG already exists
data "azurerm_resource_group" "main" {
  name = "sentimentapi-rg"
}

# === 2. CLIENT CONFIG ===
data "azurerm_client_config" "current" {}

# === 3. APP SERVICE PLAN ===
resource "azurerm_service_plan" "main" {
  name                = "${var.prefix}-plan"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = "B1"  # Basic plan for Function App
}

# === 4. STORAGE ACCOUNT ===
resource "azurerm_storage_account" "main" {
  name                             = "${var.prefix}st${random_id.suffix.hex}"
  resource_group_name              = data.azurerm_resource_group.main.name
  location                         = data.azurerm_resource_group.main.location
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  allow_nested_items_to_be_public  = false
}

# === 5. KEY VAULT ===
resource "azurerm_key_vault" "main" {
  name                        = "${var.prefix}-kv"
  location                    = data.azurerm_resource_group.main.location
  resource_group_name          = data.azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Get", "List", "Set", "Delete"
    ]
  }

  depends_on = [data.azurerm_resource_group.main]
}

# === 6. SQL SERVER ===
resource "azurerm_mssql_server" "main" {
  name                         = "${var.prefix}-sqlsrv"
  resource_group_name           = data.azurerm_resource_group.main.name
  location                      = data.azurerm_resource_group.main.location
  administrator_login           = "sqladminuser"
  administrator_login_password  = "P@ssword1234!"
  version                       = "12.0"
}

# === 7. SQL DATABASE ===
resource "azurerm_mssql_database" "main" {
  name      = "${var.prefix}-db"
  server_id = azurerm_mssql_server.main.id
  sku_name  = "S0"
}

# === 8. FUNCTION APP ===
resource "azurerm_linux_function_app" "main" {
  name                = "${var.prefix}-func"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true

  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "python"
    "AzureWebJobsStorage"      = azurerm_storage_account.main.primary_connection_string
  }

  depends_on = [
    azurerm_storage_account.main
  ]
}
