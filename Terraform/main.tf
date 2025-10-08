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

provider "docker" {}

resource "docker_network" "mlops_net" {
  name = "mlops_net"
}

resource "docker_volume" "pg_data"{ 
    name = "pg_data" 
    }
resource "docker_volume" "minio_data" { 
    name = "minio_data" 
    }
resource "docker_volume" "mlflow_art" { 
    name = "mlflow_art" 
    } 
resource "docker_volume" "prom_data"  { 
    name = "prom_data" 
    }
resource "docker_volume" "graf_data"  { 
    name = "graf_data" 
    }

# ---------- Images ----------
data "docker_image" "postgres"  { name = "postgres:15-alpine" }
data "docker_image" "minio"     { name = "minio/minio:latest" }
data "docker_image" "mlflow"    { name = "ghcr.io/mlflow/mlflow:latest" } # community image
data "docker_image" "airflow"   { name = "apache/airflow:2.9.3" }
data "docker_image" "prom"      { name = "prom/prometheus:latest" }
data "docker_image" "grafana"   { name = "grafana/grafana:latest" }

# Build the FastAPI image from local Dockerfile
resource "docker_image" "fastapi" {
  name = "mlops-fastapi:latest"
  build {
    context = "${path.root}/../services/fastapi"
    dockerfile = "Dockerfile"
  }
}

# ---------- Postgres ----------
resource "docker_container" "postgres" {
  name  = "pg"
  image = data.docker_image.postgres.name
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

  networks_advanced {
    name = docker_network.mlops_net.name
  }
}

# ---------- MinIO (S3-compatible) ----------
resource "docker_container" "minio" {
  name  = "minio"
  image = data.docker_image.minio.name
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

  networks_advanced {
    name = docker_network.mlops_net.name
  }
}

# ---------- MLflow (using Postgres backend + MinIO artifacts) ----------
resource "docker_container" "mlflow" {
  name  = "mlflow"
  image = data.docker_image.mlflow.name
  restart = "unless-stopped"

  env = [
    "MLFLOW_BACKEND_STORE_URI=postgresql+psycopg2://${var.pg_user}:${var.pg_password}@pg:5432/${var.pg_db}",
    "MLFLOW_S3_ENDPOINT_URL=http://minio:9000",
    "AWS_ACCESS_KEY_ID=${var.minio_access_key}",
    "AWS_SECRET_ACCESS_KEY=${var.minio_secret_key}"
  ]

  command = ["mlflow", "server", "--host", "0.0.0.0", "--port", "5000",
             "--backend-store-uri", "postgresql+psycopg2://${var.pg_user}:${var.pg_password}@pg:5432/${var.pg_db}",
             "--default-artifact-root", "s3://${var.minio_bucket}/"]

  ports {
    internal = 5000
    external = 5000
  }

  networks_advanced {
    name = docker_network.mlops_net.name
  }

  depends_on = [
    docker_container.postgres,
    docker_container.minio
  ]
}

# ---------- FastAPI Inference Service ----------
resource "docker_container" "fastapi" {
  name  = "fastapi"
  image = docker_image.fastapi.name
  restart = "unless-stopped"

  env = [
    "DATABASE_URL=postgresql://${var.pg_user}:${var.pg_password}@pg:5432/${var.pg_db}",
    "MLFLOW_TRACKING_URI=http://mlflow:5000",
    "S3_ENDPOINT=http://minio:9000",
    "AWS_ACCESS_KEY_ID=${var.minio_access_key}",
    "AWS_SECRET_ACCESS_KEY=${var.minio_secret_key}",
    "ARTIFACT_BUCKET=${var.minio_bucket}"
  ]

  ports {
    internal = 8000
    external = 8000
  }

  networks_advanced {
    name = docker_network.mlops_net.name
  }

  depends_on = [
    docker_container.mlflow,
    docker_container.postgres
  ]
}

# ---------- Airflow (scheduler + webserver in one container for simplicity) ----------
resource "docker_container" "airflow" {
  name  = "airflow"
  image = data.docker_image.airflow.name
  restart = "unless-stopped"

  env = [
    "AIRFLOW__CORE__LOAD_EXAMPLES=False",
    "AIRFLOW__WEBSERVER__RBAC=True",
    "AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://${var.pg_user}:${var.pg_password}@pg:5432/${var.pg_db}",
    "MLFLOW_TRACKING_URI=http://mlflow:5000",
    "S3_ENDPOINT=http://minio:9000",
    "AWS_ACCESS_KEY_ID=${var.minio_access_key}",
    "AWS_SECRET_ACCESS_KEY=${var.minio_secret_key}",
    "ARTIFACT_BUCKET=${var.minio_bucket}"
  ]

  # Run webserver; you can add scheduler via command override or docker-compose style if you prefer
  command = ["bash", "-c", "airflow db init && airflow users create --username admin --firstname a --lastname b --role Admin --email admin@example.com --password admin || true && airflow webserver -p 8080"]

  ports {
    internal = 8080
    external = 8080
  }

  volumes {
    host_path      = "${path.root}/../services/airflow/dags"
    container_path = "/opt/airflow/dags"
    read_only      = false
  }

  networks_advanced {
    name = docker_network.mlops_net.name
  }

  depends_on = [
    docker_container.postgres,
    docker_container.mlflow,
    docker_container.minio
  ]
}

# ---------- Prometheus ----------
resource "docker_container" "prometheus" {
  name  = "prometheus"
  image = data.docker_image.prom.name
  restart = "unless-stopped"

  ports {
    internal = 9090
    external = 9090
  }

  volumes {
    host_path      = "${path.root}/prometheus.yml"
    container_path = "/etc/prometheus/prometheus.yml"
    read_only      = true
  }

  networks_advanced {
    name = docker_network.mlops_net.name
  }
}

# ---------- Grafana ----------
resource "docker_container" "grafana" {
  name  = "grafana"
  image = data.docker_image.grafana.name
  restart = "unless-stopped"

  ports {
    internal = 3000
    external = 3000
  }

  networks_advanced {
    name = docker_network.mlops_net.name
  }

  depends_on = [ docker_container.prometheus ]
}

# ---------- Outputs ----------
output "mlflow_ui"   { value = "http://localhost:5000" }
output "api_url"     { value = "http://localhost:8000/docs" }
output "airflow_ui"  { value = "http://localhost:8080" }
output "minio_ui"    { value = "http://localhost:9001 (user: ${var.minio_access_key})" }
output "prometheus"  { value = "http://localhost:9090" }
output "grafana"     { value = "http://localhost:3000 (default admin/admin)" }
