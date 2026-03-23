from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator
from airflow.providers.cncf.kubernetes.sensors.spark_kubernetes import SparkKubernetesSensor

default_args = {
    'owner': 'data-engineering',
    'start_date': datetime(2023, 10, 1),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

with DAG(
    'daily_clinic_encounters_etl',
    default_args=default_args,
    schedule_interval='@daily',
    catchup=False,
) as dag:

    submit_spark_job = SparkKubernetesOperator(
        task_id='submit_bronze_to_silver_job',
        namespace='data-stack',
        application_file='scripts/etl/silver-etl-job.yaml',
        kubernetes_conn_id='kubernetes_default',
        do_xcom_push=True,
    )

    monitor_spark_job = SparkKubernetesSensor(
        task_id='monitor_bronze_to_silver_job',
        namespace='data-stack',
        application_name="{{ task_instance.xcom_pull(task_ids='submit_bronze_to_silver_job')['metadata']['name'] }}",
        kubernetes_conn_id='kubernetes_default',
    )

    submit_spark_job >> monitor_spark_job
