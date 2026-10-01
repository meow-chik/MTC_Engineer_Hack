#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl delete -f "${ROOT_DIR}/k8s/logging/logging.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/monitoring/monitoring.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/gateway/gateway.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/app/app.yaml" --ignore-not-found
kubectl delete -f https://github.com/envoyproxy/gateway/releases/download/v1.9.2/install.yaml --ignore-not-found || true
