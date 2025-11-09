import logging
import os
import azure.functions as func
import pyodbc
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("Processing request for /api/orders")

    try:
        # 1️⃣ Authenticate to Key Vault
        keyvault_url = os.environ["KEYVAULT_URI"]  # e.g. "https://sentapi-kv.vault.azure.net/"
        credential = DefaultAzureCredential()
        client = SecretClient(vault_url=keyvault_url, credential=credential)

        # 2️⃣ Fetch SQL connection string from Key Vault
        sql_secret = client.get_secret("SqlConnectionString").value

        # 3️⃣ Connect to Azure SQL
        conn = pyodbc.connect(sql_secret)
        cursor = conn.cursor()

        # 4️⃣ Execute query (simulate fetching orders)
        cursor.execute("SELECT TOP 5 OrderID, CustomerName, TotalAmount FROM Orders")
        rows = cursor.fetchall()

        # 5️⃣ Prepare response JSON
        results = [
            {"OrderID": r[0], "CustomerName": r[1], "TotalAmount": float(r[2])}
            for r in rows
        ]

        return func.HttpResponse(
            body=str(results),
            status_code=200,
            mimetype="application/json"
        )

    except Exception as e:
        logging.error(f"Error: {str(e)}")
        return func.HttpResponse(f"Error occurred: {str(e)}", status_code=500)
