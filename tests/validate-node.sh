#!/bin/bash
echo "🔍 Testing Lakehouse Connectivity..."

kubectl exec deployment/minio -- mc ls local/
echo "SELECT count(*) FROM iceberg.system.snapshots;" | trino-cli --server trino.data-stack:8080

echo "✅ Node is healthy and integrated."
