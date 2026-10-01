#!/usr/bin/env bash
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

kubectl get gatewayclass public-gateway >/dev/null || fail 'GatewayClass missing'
kubectl -n app get gateway public-gateway >/dev/null || fail 'Gateway missing'
kubectl -n app get httproute app-route >/dev/null || fail 'HTTPRoute missing'

ENVOY_SERVICE=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=public-gateway \
  -o jsonpath='{.items[0].metadata.name}')
[[ -n "$ENVOY_SERVICE" ]] || fail 'Envoy service not found'

NODE_PORT=$(kubectl -n envoy-gateway-system get svc "$ENVOY_SERVICE" \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

[[ -n "$NODE_PORT" ]] || fail 'NodePort not found'
[[ -n "$NODE_IP" ]] || fail 'Node IP not found'

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
curl -fsS -H 'Host: app.mts-hack.local' "http://${NODE_IP}:${NODE_PORT}/" | tee "$TMP"
grep -q 'Hello from MTS ENGINEER HACK!' "$TMP" || fail 'Unexpected application response'

echo

echo 'Gateway API: OK'
echo "Endpoint: http://${NODE_IP}:${NODE_PORT}/"

echo

echo 'Prometheus targets:'
kubectl -n monitoring exec deploy/prometheus -- \
  wget -qO- http://127.0.0.1:9090/api/v1/targets \
  | grep -q 'kube-state-metrics' || fail 'kube-state-metrics target not found in Prometheus API'
echo 'Prometheus: kube-state-metrics target discovered'

echo
curl -fsS -H 'Host: app.mts-hack.local' "http://${NODE_IP}:${NODE_PORT}/log-check" >/dev/null
sleep 8

kubectl -n logging port-forward svc/opensearch 19200:9200 >/tmp/mts-opensearch-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true; rm -f "$TMP"' EXIT
sleep 3

curl -fsS 'http://127.0.0.1:19200/_cluster/health' >/dev/null || fail 'OpenSearch is unavailable'
SEARCH=$(curl -fsS 'http://127.0.0.1:19200/fluentd-*/_search?q=log-check&pretty')
echo "$SEARCH" | grep -q 'log-check' || fail 'log-check was not found in OpenSearch'
echo 'Logging: OK (Fluentd -> OpenSearch)'

echo
printf 'Smoke test passed.\n'
