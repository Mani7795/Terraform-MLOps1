# Terraform-MLOps


## Customer Churn MLOps (Terraform + Docker,Local)
This project sets up a local MLOps pipeline that automatically trains, registers, serves, and monitors a customer churn prediction model

*Infra as Code*: Terraform spins up Postgres, MinIO, MLflow, Airflow, FastAPI, Prometheus, Grafana on one Docker network

*Training*: Airflow runs train.py (scikit-learn). Metrics + artifacts logged to MLflow (artifacts in MinIO)

*Model Registry*: MLflow registers churn_model and promotes the latest version to Production

*Serving*: FastAPI /predict returns churn probability and logs predictions to Postgres

*Observability*: Prometheus scrapes FastAPI metrics; Grafana visualizes them

### Stack

* IaC / Runtime: Terraform, Docker provider, Docker network/volumes

* Data & Storage: PostgreSQL (MLflow backend + predictions), MinIO (S3 compatible)

* ML Lifecycle: MLflow (tracking + registry), scikit-learn

* Orchestration: Apache Airflow

* Serving: FastAPI + Uvicorn

* Observability: Prometheus + Grafana