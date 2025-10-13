terraform {
  required_version = ">= 1.6.0"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

locals {
  # Absolute paths based on the folder that contains THIS main.tf
  repo_root      = abspath("${path.module}/..")
  dags_dir       = abspath("${path.module}/../services/airflow/dags")
  fastapi_ctx    = abspath("${path.module}/../services/fastapi")
  prometheus_cfg = abspath("${path.module}/prometheus.yaml")
}

provider "docker" {}

# ---------- Network & Volumes ----------
resource "docker_network" "mlops_net" {
  name = "mlops_net"
}

resource "docker_volume" "pg_data" {
  name = "pg_data"
}
resource "docker_volume" "minio_data" {
  name = "minio_data"
}
resource "docker_volume" "prom_data" {
  name = "prom_data"
}
resource "docker_volume" "graf_data" {
  name = "graf_data"
}

# ---------- Images ----------
data "docker_image" "postgres" {
  name = "postgres:15-alpine"
}
data "docker_image" "minio" {
  name = "minio/minio:latest"
}
data "docker_image" "mlflow" {
  name = "ghcr.io/mlflow/mlflow:latest"
}
data "docker_image" "airflow" {
  name = "apache/airflow:2.9.3-python3.11"
}
data "docker_image" "prom" {
  name = "prom/prometheus:latest"
}
data "docker_image" "grafana" {
  name = "grafana/grafana:latest"
}
resource "docker_image" "py" {
  name         = "python:3.11-slim"
  keep_locally = true
}

# Build the FastAPI image from local Dockerfile
resource "docker_image" "fastapi" {
  name = "mlops-fastapi:latest"
  keep_locally = true
  build {
    context    = local.fastapi_ctx
    dockerfile = "Dockerfile"
  }
}

# ---------- Postgres ----------
resource "docker_container" "postgres" {
  name    = "pg"
  image   = data.docker_image.postgres.name
  restart = "unless-stopped"

  env = [
    "POSTGRES_USER=${var.pg_user}",
    "POSTGRES_PASSWORD=${var.pg_password}",
    "POSTGRES_DB=${var.pg_db}"
  ]

  ports {
    internal = 5432
    external = 5432
  }

  volumes {
    volume_name    = docker_volume.pg_data.name
    container_path = "/var/lib/postgresql/data"
  }

  networks_advanced { name = docker_network.mlops_net.name }
}
resource "docker_container" "bucket_bootstrap" {
  name    = "bucket-bootstrap"
  image   = docker_image.py.name
  restart = "no"

  env = [
    "MINIO_ACCESS=${var.minio_access_key}",
    "MINIO_SECRET=${var.minio_secret_key}",
    "BUCKET=${var.minio_bucket}"
  ]

  command = [
    "bash", "-c",
    "pip install --no-cache-dir boto3 && python - <<'PY'\n",
    "import os, boto3, botocore\n",
    "s3 = boto3.client('s3', endpoint_url='http://minio:9000',\n",
    "    aws_access_key_id=os.environ['MINIO_ACCESS'],\n",
    "    aws_secret_access_key=os.environ['MINIO_SECRET'])\n",
    "b = os.environ['BUCKET']\n",
    "try:\n",
    "    s3.head_bucket(Bucket=b)\n",
    "    print('Bucket exists:', b)\n",
    "except botocore.exceptions.ClientError:\n",
    "    s3.create_bucket(Bucket=b)\n",
    "    print('Bucket created:', b)\n",
    "PY"
  ]

  networks_advanced { name = docker_network.mlops_net.name }
  depends_on = [docker_container.minio]
}
# ---------- MinIO (S3-compatible) ----------
resource "docker_container" "minio" {
  name    = "minio"
  image   = data.docker_image.minio.name
  restart = "unless-stopped"

  env = [
    "MINIO_ROOT_USER=${var.minio_access_key}",
    "MINIO_ROOT_PASSWORD=${var.minio_secret_key}"
  ]

  command = ["server", "/data", "--console-address", ":9001"]

  ports {
    internal = 9000
    external = 9000
  }
  ports {
    internal = 9001
    external = 9001
  }

  volumes {
    volume_name    = docker_volume.minio_data.name
    container_path = "/data"
  }

  networks_advanced { name = docker_network.mlops_net.name }
}



# ---------- MLflow (Postgres backend + MinIO artifacts) ----------
resource "docker_container" "mlflow" {
  name    = "mlflow"
  image   = data.docker_image.mlflow.name
  restart = "unless-stopped"

  env = [
    "MLFLOW_S3_ENDPOINT_URL=http://minio:9000",
    "AWS_ACCESS_KEY_ID=${var.minio_access_key}",
    "AWS_SECRET_ACCESS_KEY=${var.minio_secret_key}"
  ]

  command = [
    "mlflow", "server",
    "--host", "0.0.0.0", "--port", "5000",
    "--backend-store-uri", "postgresql+psycopg2://${var.pg_user}:${var.pg_password}@pg:5432/${var.pg_db}",
    "--default-artifact-root", "s3://${var.minio_bucket}/"
  ]

  ports {
    internal = 5000
    external = 5000
  }

  networks_advanced { name = docker_network.mlops_net.name }

  depends_on = [
    docker_container.postgres,
    docker_container.minio,
    docker_container.bucket_bootstrap
  ]
}

# ---------- FastAPI Inference Service ----------
resource "docker_container" "fastapi" {
  name    = "fastapi"
  image   = docker_image.fastapi.name
  restart = "unless-stopped"

  env = [
    "DB_HOST=pg",
    "DB_PORT=5432",
    "DB_NAME=${var.pg_db}",
    "DB_USER=${var.pg_user}",
    "DB_PASSWORD=${var.pg_password}",
    "MLFLOW_TRACKING_URI=http://mlflow:5000",
    "S3_ENDPOINT=http://minio:9000",
    "AWS_ACCESS_KEY_ID=${var.minio_access_key}",
    "AWS_SECRET_ACCESS_KEY=${var.minio_secret_key}",
    "ARTIFACT_BUCKET=${var.minio_bucket}",

    # Switch to true after first successful training to load model from MLflow
    "USE_MLFLOW_MODEL=false",
    "MODEL_NAME=churn_model"
  ]

  ports {
    internal = 8000
    external = 8000
  }

  networks_advanced { name = docker_network.mlops_net.name }

  depends_on = [
    docker_container.mlflow,
    docker_container.postgres
  ]
}

# ---------- Airflow (scheduler + webserver) ----------
resource "docker_container" "airflow" {
  name    = "airflow"
  image   = data.docker_image.airflow.name
  restart = "unless-stopped"

  env = [
    "AIRFLOW__CORE__LOAD_EXAMPLES=False",
    "AIRFLOW__WEBSERVER__RBAC=True",
    "AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////opt/airflow/airflow.db",

    "MLFLOW_TRACKING_URI=http://mlflow:5000",
    "S3_ENDPOINT=http://minio:9000",
    "AWS_ACCESS_KEY_ID=${var.minio_access_key}",
    "AWS_SECRET_ACCESS_KEY=${var.minio_secret_key}",
    "ARTIFACT_BUCKET=${var.minio_bucket}"
  ]

  # Install deps, init Airflow, create user, start scheduler + webserver
  command = [
    "bash", "-c",
    "pip install --no-cache-dir mlflow==2.16.0 scikit-learn==1.5.1 pandas==2.2.2 boto3==1.34.* psycopg2-binary==2.9.9 && ",
    "airflow db init && ",
    "airflow users create --username admin --firstname a --lastname b --role Admin --email admin@example.com --password admin || true && ",
    "airflow scheduler & airflow webserver -p 8080"
  ]

  ports {
    internal = 8080
    external = 8080
  }

  volumes {
    host_path      = local.dags_dir
    container_path = "/opt/airflow/dags"
    read_only      = false
  }

  networks_advanced { name = docker_network.mlops_net.name }

  depends_on = [
    docker_container.mlflow,
    docker_container.minio,
    docker_container.postgres
  ]
}

# ---------- Prometheus ----------
resource "docker_container" "prometheus" {
  name    = "prometheus"
  image   = data.docker_image.prom.name
  restart = "unless-stopped"

  ports {
    internal = 9090
    external = 9092
  }

  volumes {
    host_path      = local.prometheus_cfg # was ./prometheus.yml
    container_path = "/etc/prometheus/prometheus.yaml"
    read_only      = true
  }

  networks_advanced { name = docker_network.mlops_net.name }
}

# ---------- Grafana ----------
resource "docker_container" "grafana" {
  name    = "grafana"
  image   = data.docker_image.grafana.name
  restart = "unless-stopped"

  ports {
    internal = 3000
    external = 3000
  }

  networks_advanced { name = docker_network.mlops_net.name }

  depends_on = [docker_container.prometheus]
}

# ---------- Outputs ----------
output "mlflow_ui" { value = "http://localhost:5000" }
output "api_url" { value = "http://localhost:8000/docs" }
output "airflow_ui" { value = "http://localhost:8080" }
output "minio_ui" { value = "http://localhost:9001 (user: ${var.minio_access_key})" }
output "prometheus" { value = "http://localhost:9090" }
output "grafana" { value = "http://localhost:3000 (default admin/admin)" }