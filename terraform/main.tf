terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
  
  # This backend block is configured by the GitHub Action
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

# === 1. BASE ===
variable "prefix" {
  description = "A prefix for all resource names"
  type        = string
  default     = "proj1"
}

variable "location" {
  description = "Azure region to deploy to"
  type        = string
  default     = "East US"
}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# === 2. KEY VAULT ===
# The vault to hold our SQL password
resource "azurerm_key_vault" "main" {
  name                = "${var.prefix}kv${random_id.suffix.hex}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

resource "random_id" "suffix" {
  byte_length = 4
}

data "azurerm_client_config" "current" {}

# === 3. SQL DATABASE ===
# A random password for the SQL admin
resource "random_password" "sql_pass" {
  length  = 16
  special = true
}

# The SQL Server
resource "azurerm_mssql_server" "main" {
  name                         = "${var.prefix}-sqlserver"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = random_password.sql_pass.result
}

# The SQL Database
resource "azurerm_mssql_database" "main" {
  name                = "guestbook-db"
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_sql_server.main.name
  location            = azurerm_resource_group.main.location
  sku_name            = "S0" # A basic, cheap SKU
}

# Firewall rule to allow Azure services to access the DB
resource "azurerm_sql_firewall_rule" "azure" {
  name                = "AllowAzureServices"
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_sql_server.main.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

# === 4. KEY VAULT SECRET ===
# The *full connection string* that our app needs.
# We build it here and store it as ONE secret.
resource "azurerm_key_vault_secret" "db_conn_string" {
  name         = "DB-CONNECTION-STRING"
  key_vault_id = azurerm_key_vault.main.id
  value        = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:${azurerm_sql_server.main.fully_qualified_domain_name},1433;Database=${azurerm_sql_database.main.name};Uid=${azurerm_sql_server.main.administrator_login};Pwd=${random_password.sql_pass.result};Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
  
  # Ensure SQL server is created before this
  depends_on = [azurerm_sql_server.main]
}

# === 5. APP SERVICE ===
# The App Service Plan (the "hardware")
resource "azurerm_service_plan" "main" {
  name                = "${var.prefix}-asp"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "B1" # Basic SKU
}

# The App Service (the "app")
resource "azurerm_linux_web_app" "main" {
  name                = "${var.prefix}-webapp"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true

  # This is the MAGIC: Enable Managed Identity
  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.9"
    }
    startup_file = "startup.txt"
  }
  
  # This is the OTHER MAGIC:
  # 1. We create an app setting called "DB_CONNECTION_STRING"
  # 2. Its value is a *reference* to the secret in Key Vault.
  # App Service will use its Managed Identity to fetch this at runtime.
  app_settings = {
    "DB_CONNECTION_STRING" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.db_conn_string.id})"
  }
  
  # Give time for identity to be created
  depends_on = [azurerm_key_vault_secret.db_conn_string]
}

# === 6. APP SERVICE PERMISSIONS ===
# Grant the App Service's Managed Identity permission to GET secrets
# from our Key Vault.
resource "azurerm_key_vault_access_policy" "app_identity" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = azurerm_linux_web_app.main.identity[0].tenant_id
  object_id    = azurerm_linux_web_app.main.identity[0].principal_id

  secret_permissions = [
    "Get", "List"
  ]
}

# === 7. APPLICATION GATEWAY ===
resource "azurerm_public_ip" "appgw" {
  name                = "${var.prefix}-appgw-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network" "appgw" {
  name                = "${var.prefix}-vnet-appgw"
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
    enabled        = true
    firewall_mode  = "Prevention"
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
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

  # Backend pool points to the app service
  backend_address_pool {
    name = "app-service-pool"
    fqdns = [azurerm_linux_web_app.main.default_hostname]
  }

  # Settings for the backend
  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
    # Tell AppGw to trust the App Service hostname
    pick_host_name_from_backend_address = true 
  }

  # Listener for public traffic
  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "public-ip-config"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  # Routing rule to tie it all together
  request_routing_rule {
    name               = "http-rule"
    rule_type          = "Basic"
    http_listener_name = "http-listener"
    backend_address_pool_name = "app-service-pool"
    backend_http_settings_name = "http-settings"
  }
}

# === 8. OUTPUTS ===
output "app_service_name" {
  value = azurerm_linux_web_app.main.name
}

output "app_gateway_public_ip" {
  description = "The public IP of the Application Gateway. Access the app here."
  value       = azurerm_public_ip.appgw.ip_address
}