FROM quay.io/jupyter/pyspark-notebook:spark-3.5.0

USER root
# Install system deps and download Spark jars as root — /usr/local/spark/jars is root-owned
# in the base image and cannot be written to by jovyan (NB_UID).
RUN apt-get update \
    && apt-get install -y libgdal-dev libproj-dev g++ \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /usr/local/spark/jars \
    && wget -q https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/1.5.0/iceberg-spark-runtime-3.5_2.12-1.5.0.jar -P /usr/local/spark/jars/ \
    && wget -q https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar -P /usr/local/spark/jars/ \
    && wget -q https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar -P /usr/local/spark/jars/

USER ${NB_UID}
RUN pip install --no-cache-dir geopandas shapely folium statsmodels scipy mlflow boto3 pyarrow delta-spark

ENV MLFLOW_TRACKING_URI=http://mlflow.data-stack.svc.cluster.local:5000
ENV AWS_ENDPOINT_URL=http://minio.data-stack.svc.cluster.local:9000

WORKDIR /home/jovyan/work
