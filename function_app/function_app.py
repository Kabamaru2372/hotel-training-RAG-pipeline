import logging
import os

import azure.functions as func
import requests
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()


@app.event_grid_trigger(arg_name="event")
def on_upload(event: func.EventGridEvent):
    data = event.get_json()
    blob_url: str = data["url"]
    blob_name = blob_url.split("/")[-1]

    logging.info("Blob uploaded: %s", blob_name)

    blob_service = BlobServiceClient.from_connection_string(os.environ["STORAGE_CONN_STR"])
    content = (
        blob_service
        .get_blob_client("hotel-data", blob_name)
        .download_blob()
        .readall()
    )

    rag_url = os.environ["RAG_APP_URL"].rstrip("/")
    response = requests.post(
        f"{rag_url}/ingest",
        files={"file": (blob_name, content)},
        timeout=60,
    )
    response.raise_for_status()
    logging.info("Ingested %s — status %s", blob_name, response.status_code)
