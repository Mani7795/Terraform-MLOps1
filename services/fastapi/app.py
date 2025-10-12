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
conn = psycopg2.connect(
    dbname=os.getenv("DATABASE_URL").split("/")[-1],
    user=os.getenv("DATABASE_URL").split("//")[1].split(":")[0],
    password=os.getenv("DATABASE_URL").split(":")[2].split("@")[0],
    host=os.getenv("DATABASE_URL").split("@")[1].split(":")[0],
    port=os.getenv("DATABASE_URL").split(":")[-1]
)
cur = conn.cursor()
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
