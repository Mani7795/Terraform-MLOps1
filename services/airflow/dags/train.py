
import os, warnings
warnings.filterwarnings("ignore")

import pandas as pd
import mlflow
import mlflow.sklearn
from sklearn.model_selection import train_test_split
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score

# MLflow tracking
mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI","http://mlflow:5000"))
experiment_name = "churn_experiment"
mlflow.set_experiment(experiment_name)

# Data
csv_path = "/opt/airflow/dags/customers_sample.csv"
df = pd.read_csv(csv_path)

features = ["tenure_months","monthly_spend","complaints_last_90d"]
target = "churned"

X = df[features]
y = df[target]

X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42, stratify=y)

with mlflow.start_run(run_name="logreg_baseline"):
    C = 1.0  # regularization inverse strength
    max_iter = 200

    model = LogisticRegression(C=C, max_iter=max_iter)
    model.fit(X_train, y_train)

    preds_proba = model.predict_proba(X_test)[:,1]
    auc = roc_auc_score(y_test, preds_proba)

    mlflow.log_param("C", C)
    mlflow.log_param("max_iter", max_iter)
    mlflow.log_metric("auc", float(auc))

    mlflow.sklearn.log_model(model, artifact_path="model", registered_model_name="churn_model")

    # Promote to Production (simple demo)
    from mlflow.tracking import MlflowClient
    client = MlflowClient()
    run_id = mlflow.active_run().info.run_id

    # Find the latest model version created by this run
    mv = client.search_model_versions("name='churn_model'")[-1]
    version = mv.version

    # Transition to Production
    client.transition_model_version_stage(
        name="churn_model",
        version=version,
        stage="Production",
        archive_existing_versions=True,
    )

print("Training complete. Model registered as 'churn_model' in Production.")
