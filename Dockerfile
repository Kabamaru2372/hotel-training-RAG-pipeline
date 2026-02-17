FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

# Persist ChromaDB across restarts
VOLUME ["/app/chroma"]

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]