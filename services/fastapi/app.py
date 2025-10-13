from fastapi import FastAPI
from pydantic import BaseModel
import os, time
import psycopg2
from prometheus_client import Counter, Histogram, generate_latest
from fastapi.responses import PlainTextResponse

app = FastAPI(title="Churn Inference API")

# Metrics
REQS = Counter("inference_requests_total", "Total inference requests")
LAT  = Histogram("inference_latency_seconds", "Inference latency")

# DB
DB_HOST = os.getenv("DB_HOST", "pg")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "mlopsdb")
DB_USER = os.getenv("DB_USER", "mlops")
DB_PASSWORD = os.getenv("DB_PASSWORD", "mlops_pass")

conn = psycopg2.connect(
    host=DB_HOST,
    port=DB_PORT,
    dbname=DB_NAME,
    user=DB_USER,
    password=DB_PASSWORD
)
cur = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
cur.execute("""
CREATE TABLE IF NOT EXISTS predictions(
  id SERIAL PRIMARY KEY,
  customer_id TEXT,
  prob_churn FLOAT,
  predicted_at TIMESTAMP DEFAULT NOW()
)
""")
conn.commit()

class Customer(BaseModel):
    customer_id: str
    tenure_months: int
    monthly_spend: float
    complaints_last_90d: int

@app.get("/health")
def health(): return {"status": "ok"}

@app.get("/metrics", response_class=PlainTextResponse)
def metrics():
    return PlainTextResponse(generate_latest().decode("utf-8"))

@app.post("/predict")
def predict(cust: Customer):
    REQS.inc()
    start = time.time()
    # Fake model: logistic-ish score as a demo
    score = min(0.99, max(0.01, 0.5 + 0.3*(cust.complaints_last_90d>0) - 0.002*cust.tenure_months + 0.001*cust.monthly_spend))
    LAT.observe(time.time() - start)

    cur.execute("INSERT INTO predictions (customer_id, prob_churn) VALUES (%s, %s)", (cust.customer_id, score))
    conn.commit()
    return {"customer_id": cust.customer_id, "prob_churn": score}
