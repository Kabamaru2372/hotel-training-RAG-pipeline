# trigger.py — lightweight Azure Function (optional, keeps app.py clean)
import os
import azure.functions as func
import requests
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()

@app.event_grid_trigger(arg_name="event")
def on_upload(event: func.EventGridEvent):
    data = event.get_json()
    blob_name = data["url"].split("/")[-1]

    # Download blob and forward to the RAG app
    blob_client = BlobServiceClient.from_connection_string(os.environ["STORAGE_CONN_STR"])
    content = blob_client.get_blob_client("hotel-data", blob_name).download_blob().readall()

    requests.post(
        f"{os.environ['RAG_APP_URL']}/ingest",
        files={"file": (blob_name, content)}
    )