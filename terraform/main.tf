terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }

  # Backend configured in GitHub Actions
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

# === 1. BASE ===
variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "proj1"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "East US"
}

resource "random_id" "suffix" {
  byte_length = 4
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# === 2. KEY VAULT ===
resource "azurerm_key_vault" "main" {
  name                = "${var.prefix}kv${random_id.suffix.hex}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

# === 3. SQL DATABASE ===
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
  name      = "guestbook-db"
  server_id = azurerm_mssql_server.main.id
  sku_name  = "S0"
}

resource "azurerm_mssql_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# === 4. STORE CONNECTION STRING IN KEY VAULT ===
resource "azurerm_key_vault_secret" "db_conn_string" {
  name         = "DB-CONNECTION-STRING"
  key_vault_id = azurerm_key_vault.main.id
  value        = "Server=tcp:${azurerm_mssql_server.main.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.main.name};User ID=${azurerm_mssql_server.main.administrator_login};Password=${random_password.sql_pass.result};Encrypt=true;Connection Timeout=30;"
  
  depends_on = [azurerm_mssql_server.main]
}

# === 5. APP SERVICE PLAN ===
resource "azurerm_service_plan" "main" {
  name                = "${var.prefix}-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# === 6. FUNCTION APP (NO KV REFERENCE YET) ===
resource "azurerm_linux_function_app" "main" {
  name                = "${var.prefix}-func"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }

  # Start clean — no Key Vault refs yet
  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "python"
  }
}

# === 7. GRANT FUNCTION ACCESS TO KEY VAULT ===
resource "azurerm_key_vault_access_policy" "func_identity" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_function_app.main.identity[0].principal_id

  secret_permissions = ["Get", "List"]
}

# === 8. UPDATE FUNCTION APP SETTINGS (AFTER ACCESS POLICY) ===
resource "azurerm_linux_function_app_slot" "prod_slot" {
  name            = "production"
  function_app_id = azurerm_linux_function_app.main.id

  app_settings = {
    "DB_CONNECTION_STRING" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.db_conn_string.id})"
  }

  depends_on = [azurerm_key_vault_access_policy.func_identity]
}

# === 9. APPLICATION GATEWAY ===
resource "azurerm_public_ip" "appgw" {
  name                = "${var.prefix}-appgw-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network" "appgw" {
  name                = "${var.prefix}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.1.0.0/16"]
}

resource "azurerm_subnet" "appgw" {
  name                 = "appgw-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.appgw.name
  address_prefixes     = ["10.1.0.0/24"]
}

resource "azurerm_application_gateway" "main" {
  name                = "${var.prefix}-appgw"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  waf_configuration {
    enabled           = true
    firewall_mode     = "Prevention"
    rule_set_type     = "OWASP"
    rule_set_version  = "3.2"
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "public-ip-config"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  backend_address_pool {
    name  = "func-pool"
    fqdns = [azurerm_linux_function_app.main.default_hostname]
  }

  backend_http_settings {
    name                            = "http-settings"
    port                            = 80
    protocol                        = "Http"
    cookie_based_affinity           = "Disabled"
    pick_host_name_from_backend_address = true
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "public-ip-config"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rule1"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "func-pool"
    backend_http_settings_name = "http-settings"
  }
}

# === 10. OUTPUTS ===
output "function_app_name" {
  value = azurerm_linux_function_app.main.name
}

output "app_gateway_ip" {
  value = azurerm_public_ip.appgw.ip_address
}
