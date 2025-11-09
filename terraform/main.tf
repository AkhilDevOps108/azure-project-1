#######################################################
# PROVIDER & VARIABLES
#######################################################
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.107.0"
    }
    random = {
      source = "hashicorp/random"
    }
  }

  required_version = ">= 1.5.0"
}

provider "azurerm" {
  features {}
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "sentimentapi"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "East US"
}

#######################################################
# RESOURCE GROUP
#######################################################
resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}

#######################################################
# STORAGE ACCOUNT
#######################################################
resource "azurerm_storage_account" "main" {
  name                     = "${var.prefix}stg"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

#######################################################
# APP SERVICE PLAN (CONSUMPTION PLAN FOR FUNCTIONS)
#######################################################
resource "azurerm_service_plan" "main" {
  name                = "${var.prefix}-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan
}

#######################################################
# FUNCTION APP
#######################################################
resource "azurerm_linux_function_app" "main" {
  name                       = "${var.prefix}-func"
  resource_group_name         = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key
  functions_extension_version = "~4"
  https_only                 = true

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "python"
    "AzureWebJobsStorage"      = azurerm_storage_account.main.primary_connection_string
    "OPENAI_ENDPOINT"          = "https://YOUR_OPENAI_ENDPOINT.openai.azure.com/"
    "KEY_VAULT_NAME"           = azurerm_key_vault.main.name
  }
}

#######################################################
# SQL SERVER & DATABASE (NEW MSSQL RESOURCES)
#######################################################
resource "random_password" "sql_pass" {
  length  = 16
  special = true
}

resource "azurerm_mssql_server" "main" {
  name                         = "${var.prefix}-sqlserver"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = random_password.sql_pass.result
}

resource "azurerm_mssql_database" "main" {
  name      = "sentimentdb"
  server_id = azurerm_mssql_server.main.id
  sku_name  = "S0"
}

resource "azurerm_mssql_firewall_rule" "azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

#######################################################
# KEY VAULT & SECRET
#######################################################
resource "azurerm_key_vault" "main" {
  name                        = "${var.prefix}-kv"
  location                    = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = azurerm_linux_function_app.main.identity[0].principal_id

    secret_permissions = ["Get", "List"]
  }
}

resource "azurerm_key_vault_secret" "db_conn_string" {
  name         = "DB-CONNECTION-STRING"
  key_vault_id = azurerm_key_vault.main.id
  value        = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:${azurerm_mssql_server.main.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.main.name};Uid=${azurerm_mssql_server.main.administrator_login};Pwd=${random_password.sql_pass.result};Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
  
  depends_on = [azurerm_mssql_server.main]
}

data "azurerm_client_config" "current" {}

#######################################################
# OUTPUTS
#######################################################
output "function_app_url" {
  description = "URL of the Function App"
  value       = azurerm_linux_function_app.main.default_hostname
}

output "sql_server_name" {
  description = "Deployed SQL Server"
  value       = azurerm_mssql_server.main.name
}

output "key_vault_name" {
  description = "Key Vault for secrets"
  value       = azurerm_key_vault.main.name
}
