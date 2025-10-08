from airflow import DAG
from airflow.operators.bash import BashOperator
from datetime import datetime

default_args = {"owner": "airflow", "retries": 0}
with DAG(
    dag_id="retrain_churn",
    start_date=datetime(2025, 1, 1),
    schedule="0 3 * * 1",  # Mondays at 3AM
    catchup=False,
    default_args=default_args,
    description="Retrain churn model and log to MLflow",
) as dag:

    # In a real project, call python to train and log to MLflow
    train = BashOperator(
        task_id="train",
        bash_command="echo 'simulate training... logging to MLflow' && sleep 5"
    )
