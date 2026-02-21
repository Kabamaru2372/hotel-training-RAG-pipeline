import logging
import os

import azure.functions as func
import requests

app = func.FunctionApp()


@app.blob_trigger(arg_name="blob", path="hotel-data/{name}", connection="STORAGE_CONN_STR")
def on_upload(blob: func.InputStream):
    blob_name = blob.name
    content = blob.read()

    logging.info("Blob uploaded: %s", blob_name)

    rag_url = os.environ["RAG_APP_URL"].rstrip("/")
    response = requests.post(
        f"{rag_url}/ingest",
        files={"file": (blob_name, content)},
        timeout=60,
    )
    response.raise_for_status()
    logging.info("Ingested %s — status %s", blob_name, response.status_code)
