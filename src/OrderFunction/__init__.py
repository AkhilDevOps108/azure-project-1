import os
import json
import azure.functions as func
import pyodbc
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        # Access Key Vault
        key_vault_name = os.environ["KEYVAULT_NAME"]
        kv_uri = f"https://{key_vault_name}.vault.azure.net"
        credential = DefaultAzureCredential()
        client = SecretClient(vault_url=kv_uri, credential=credential)

        # Get SQL secrets from Key Vault
        db_user = client.get_secret("db-username").value
        db_pass = client.get_secret("db-password").value
        db_server = client.get_secret("db-server").value
        db_name = client.get_secret("db-name").value

        # Build connection string
        conn_str = (
            f"Driver={{ODBC Driver 17 for SQL Server}};"
            f"Server=tcp:{db_server},1433;"
            f"Database={db_name};"
            f"Uid={db_user};"
            f"Pwd={db_pass};"
            "Encrypt=yes;"
            "TrustServerCertificate=no;"
            "Connection Timeout=30;"
        )

        # Parse input
        req_body = req.get_json()
        name = req_body.get("name")
        item = req_body.get("item")
        qty = req_body.get("quantity")

        # Insert into SQL
        with pyodbc.connect(conn_str) as conn:
            cursor = conn.cursor()
            cursor.execute(
                "INSERT INTO Orders (CustomerName, Item, Quantity) VALUES (?, ?, ?)",
                (name, item, qty),
            )
            conn.commit()

        return func.HttpResponse(
            json.dumps({"message": f"Order placed by {name} for {qty}x {item}."}),
            mimetype="application/json",
            status_code=200
        )

    except Exception as e:
        return func.HttpResponse(
            json.dumps({"error": str(e)}),
            mimetype="application/json",
            status_code=500
        )
