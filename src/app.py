import os
from flask import Flask, request, redirect, render_template_string
import pyodbc

app = Flask(__name__)

# === CONFIGURATION ===
# The App Service provides the connection string via an environment variable
# that we configured to pull from Key Vault.
connection_string = os.environ.get("DB_CONNECTION_STRING")

# === HELPER: Get DB Connection ===
def get_db():
    try:
        conn = pyodbc.connect(connection_string)
        return conn
    except Exception as e:
        print(f"Error connecting to DB: {e}")
        return None

# === HELPER: Initialize DB ===
def init_db():
    conn = get_db()
    if conn:
        with conn.cursor() as cursor:
            # Create table if it doesn't exist
            cursor.execute("""
                IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='entries' and xtype='U')
                CREATE TABLE entries (
                    id INT IDENTITY(1,1) PRIMARY KEY,
                    guest_name NVARCHAR(50),
                    message NVARCHAR(255)
                )
            """)
            conn.commit()
        conn.close()

# === ROUTES ===
@app.route('/', methods=['GET', 'POST'])
def index():
    conn = get_db()
    if not conn:
        return "<h1>Error: Could not connect to the database.</h1><p>Check Key Vault and Managed Identity settings.</p>", 500

    if request.method == 'POST':
        name = request.form['name']
        msg = request.form['message']
        with conn.cursor() as cursor:
            cursor.execute("INSERT INTO entries (guest_name, message) VALUES (?, ?)", name, msg)
            conn.commit()
        return redirect('/')

    # GET request
    entries = []
    with conn.cursor() as cursor:
        cursor.execute("SELECT guest_name, message FROM entries ORDER BY id DESC")
        rows = cursor.fetchall()
        for row in rows:
            entries.append({"name": row.guest_name, "message": row.message})
    
    conn.close()

    # Simple HTML template in-line
    return render_template_string("""
    <html>
    <head><title>Secure Guestbook</title></head>
    <body style="font-family: sans-serif; margin: 2em;">
        <h2>Secure Guestbook (App Service -> Key Vault -> SQL DB)</h2>
        <form method="POST">
            Name: <input type="text" name="name" style="margin-right: 1em;">
            Message: <input type="text" name="message" style="margin-right: 1em;">
            <input type="submit" value="Sign">
        </form>
        <h3>Entries:</h3>
        {% for entry in entries %}
            <div>
                <strong>{{ entry.name }}:</strong> {{ entry.message }}
            </div>
        {% endfor %}
    </body>
    </html>
    """, entries=entries)

# Initialize the database on startup
init_db()