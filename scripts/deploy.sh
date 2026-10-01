#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVOY_VERSION="v1.9.2"

command -v kubectl >/dev/null || { echo 'kubectl is required'; exit 1; }

kubectl version --short 2>/dev/null || kubectl version --client

kubectl apply --server-side -f "https://github.com/envoyproxy/gateway/releases/download/${ENVOY_VERSION}/install.yaml"
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

kubectl apply -f "${ROOT_DIR}/k8s/app/app.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/gateway/gateway.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/monitoring/monitoring.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/logging/logging.yaml"

kubectl wait -n app --for=condition=Available deployment/web --timeout=180s
kubectl wait -n monitoring --for=condition=Available deployment/prometheus --timeout=180s
kubectl wait -n monitoring --for=condition=Available deployment/kube-state-metrics --timeout=180s
kubectl wait -n logging --for=condition=Ready pod/opensearch-0 --timeout=300s
kubectl rollout status -n logging daemonset/fluentd --timeout=180s

cat <<'OUT'

Deployment finished.
Run:
  ./scripts/smoke-test.sh

Gateway details:
  kubectl get gateway -n app public-gateway
  kubectl get svc -n envoy-gateway-system
OUT
