terraform {
  required_version = ">= 1.5.0"

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

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

############################################
# VARIABLES
############################################

variable "prefix" {
  default = "sentapi"
}

variable "location" {
  default = "West Europe"  # ✅ Safe region
}

############################################
# RESOURCE GROUP
############################################

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}

############################################
# RANDOM SUFFIX
############################################

resource "random_id" "suffix" {
  byte_length = 4
}

############################################
# STORAGE ACCOUNT (Required for Functions)
############################################

resource "azurerm_storage_account" "main" {
  name                     = "${var.prefix}st${random_id.suffix.hex}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

############################################
# APP SERVICE PLAN
############################################

resource "azurerm_service_plan" "main" {
  name                = "${var.prefix}-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "B1"     # ✅ Works in non-restricted regions
}

############################################
# KEY VAULT
############################################

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                        = "${var.prefix}-kv"
  location                    = var.location
  resource_group_name          = azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = ["Get", "List", "Set"]
  }
}

############################################
# SQL SERVER + DB
############################################

# === SQL SERVER + DB ===
resource "azurerm_mssql_server" "main" {
  name                         = "${var.prefix}-sqlsrv${random_id.suffix.hex}"  # ✅ unique name
  resource_group_name          = azurerm_resource_group.main.name
  location                     = "West US 2"
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = "P@ssword1234!"
}


resource "azurerm_mssql_database" "main" {
  name      = "${var.prefix}-db"
  server_id = azurerm_mssql_server.main.id
  sku_name  = "S0"
}


############################################
# FUNCTION APP
############################################

resource "azurerm_linux_function_app" "main" {
  name                = "${var.prefix}-func"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
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
    FUNCTIONS_WORKER_RUNTIME = "python"
    AzureWebJobsStorage      = azurerm_storage_account.main.primary_connection_string
  }
}
