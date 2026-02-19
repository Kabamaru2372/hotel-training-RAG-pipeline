import os
from fastapi import FastAPI, UploadFile, Request
from azure.ai.inference import ChatCompletionsClient, EmbeddingsClient
from azure.ai.inference.models import SystemMessage, UserMessage
from azure.core.credentials import AzureKeyCredential
import chromadb

app = FastAPI()

# ChromaDB — persists to disk, no separate service needed
chroma = chromadb.PersistentClient(path="./chroma")
collection = chroma.get_or_create_collection("hotels")

_endpoint = os.environ["AZURE_FOUNDRY_ENDPOINT"]
_credential = AzureKeyCredential(os.environ["AZURE_FOUNDRY_KEY"])

chat_client = ChatCompletionsClient(endpoint=_endpoint, credential=_credential)
embeddings_client = EmbeddingsClient(endpoint=_endpoint, credential=_credential)

def embed(text: str) -> list[float]:
    return embeddings_client.embed(
        input=[text], model="text-embedding-3-small"
    ).data[0].embedding

def chunk(text: str, size=400, overlap=50) -> list[str]:
    words = text.split()
    return [" ".join(words[i:i+size]) for i in range(0, len(words), size - overlap)]


# ── Ingest ──────────────────────────────────────────────
@app.post("/ingest")
async def ingest(file: UploadFile):
    content = (await file.read()).decode()
    chunks = chunk(content)

    collection.upsert(
        ids=[f"{file.filename}-{i}" for i in range(len(chunks))],
        documents=chunks,
        embeddings=[embed(c) for c in chunks],
        metadatas=[{"source": file.filename}] * len(chunks)
    )
    return {"ingested": len(chunks), "file": file.filename}


# ── Query ────────────────────────────────────────────────
@app.post("/ask")
async def ask(req: Request):
    body = await req.json()
    question = body["question"]

    results = collection.query(
        query_embeddings=[embed(question)],
        n_results=5
    )
    context = "\n\n".join(results["documents"][0])

    response = chat_client.complete(
        model="gpt-4o",
        messages=[
            SystemMessage(content="Answer using only the hotel information provided. Be concise and factual."),
            UserMessage(content=f"Context:\n{context}\n\nQuestion: {question}")
        ]
    )
    return {"answer": response.choices[0].message.content}