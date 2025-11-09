# 🚀 Project 1 — Python App Deployment on Azure using Terraform + GitHub Actions

## 🧩 Overview
This project demonstrates how to **automate infrastructure deployment and app delivery** on Microsoft Azure using:
- **Terraform** → For creating Azure resources (Function App, SQL DB, Key Vault, Storage, etc.)
- **GitHub Actions** → For CI/CD pipeline (infrastructure + application deployment)
- **Python (Flask/FastAPI)** → For the app itself

The workflow automatically provisions cloud resources, builds your app, and deploys it to Azure.

---

## ⚙️ Architecture

**Components created by Terraform:**
| Resource | Description |
|-----------|--------------|
| `azurerm_resource_group` | Resource group to host all resources |
| `azurerm_storage_account` | Backend storage for Terraform and Function App |
| `azurerm_service_plan` | App Service Plan for Function App |
| `azurerm_linux_function_app` | Serverless Function App to host Python app |
| `azurerm_key_vault` | For storing secrets securely |
| `azurerm_mssql_server` & `azurerm_mssql_database` | SQL Server and database for backend |