import logging
import json
import azure.functions as func
import pyodbc
import os
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("Processing POST request for /api/OrderFunction")

    try:
        # Authenticate to Key Vault
        keyvault_url = os.environ["KEYVAULT_URL"]
        credential = DefaultAzureCredential()
        client = SecretClient(vault_url=keyvault_url, credential=credential)
        sql_secret = client.get_secret("SqlConnectionString").value

        # Parse JSON body
        req_body = req.get_json()
        name = req_body.get("name")
        item = req_body.get("item")
        quantity = req_body.get("quantity")

        if not all([name, item, quantity]):
            return func.HttpResponse("Missing fields", status_code=400)

        # Connect to SQL
        conn = pyodbc.connect(sql_secret)
        cursor = conn.cursor()

        # Create table if not exists
        cursor.execute("""
        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='Orders' AND xtype='U')
        CREATE TABLE Orders (
            Id INT IDENTITY(1,1) PRIMARY KEY,
            CustomerName NVARCHAR(100),
            Item NVARCHAR(100),
            Quantity INT
        )
        """)

        # Insert record
        cursor.execute(
            "INSERT INTO Orders (CustomerName, Item, Quantity) VALUES (?, ?, ?)",
            (name, item, quantity)
        )
        conn.commit()

        return func.HttpResponse(
            json.dumps({"message": "Order inserted successfully!"}),
            status_code=201,
            mimetype="application/json"
        )

    except Exception as e:
        logging.error(f"Error: {str(e)}")
        return func.HttpResponse(f"Error: {str(e)}", status_code=500)
