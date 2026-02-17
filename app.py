# app.py
import os
import json
from fastapi import FastAPI, UploadFile, Request
from openai import AzureOpenAI
import chromadb

app = FastAPI()

# ChromaDB — persists to disk, no separate service needed
chroma = chromadb.PersistentClient(path="./chroma")
collection = chroma.get_or_create_collection("hotels")

oai = AzureOpenAI(
    azure_endpoint=os.environ["AZURE_OAI_ENDPOINT"],
    api_key=os.environ["AZURE_OAI_KEY"],
    api_version="2024-02-01"
)

def embed(text: str) -> list[float]:
    return oai.embeddings.create(
        input=text, model="text-embedding-3-small"
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

    response = oai.chat.completions.create(
        model="gpt-4o",
        messages=[
            {"role": "system", "content": "Answer using only the hotel information provided. Be concise and factual."},
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {question}"}
        ]
    )
    return {"answer": response.choices[0].message.content}