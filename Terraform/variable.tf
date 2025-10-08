variable "pg_user"     { type = string  default = "mlops" }
variable "pg_password" { type = string  default = "mlops_pass" }
variable "pg_db"       { type = string  default = "mlopsdb" }

variable "minio_access_key" { type = string  default = "minioadmin" }
variable "minio_secret_key" { type = string  default = "minioadmin" }
variable "minio_bucket"     { type = string  default = "mlflow-artifacts" }
