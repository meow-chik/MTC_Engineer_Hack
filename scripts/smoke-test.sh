#!/usr/bin/env bash
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

cleanup_pids=()
cleanup() {
  local pid
  for pid in "${cleanup_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  [[ -n "${TMP:-}" ]] && rm -f "$TMP"
}
trap cleanup EXIT

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2
  local i
  for ((i=1; i<=attempts; i++)); do
    if "$@"; then
      return 0
    fi
    if (( i < attempts )); then
      sleep "$delay"
    fi
  done
  return 1
}

kubectl get gatewayclass public-gateway >/dev/null || fail 'GatewayClass missing'
kubectl -n app get gateway public-gateway >/dev/null || fail 'Gateway missing'
kubectl -n app get httproute app-route >/dev/null || fail 'HTTPRoute missing'

ENVOY_SERVICE=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=public-gateway \
  -o jsonpath='{.items[0].metadata.name}')
[[ -n "$ENVOY_SERVICE" ]] || fail 'Envoy service not found'

TMP=$(mktemp)

if [[ "${SMOKE_USE_PORT_FORWARD:-false}" == "true" ]]; then
  APP_URL='http://127.0.0.1:18888/'
  kubectl -n envoy-gateway-system port-forward "svc/${ENVOY_SERVICE}" 18888:80 \
    >/tmp/mts-envoy-pf.log 2>&1 &
  cleanup_pids+=("$!")
  retry 30 1 curl -fsS -H 'Host: app.mts-hack.local' "$APP_URL" >/dev/null \
    || { cat /tmp/mts-envoy-pf.log >&2 || true; fail 'Envoy port-forward is unavailable'; }
  ENDPOINT="$APP_URL"
else
  NODE_PORT=$(kubectl -n envoy-gateway-system get svc "$ENVOY_SERVICE" \
    -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  [[ -n "$NODE_PORT" ]] || fail 'NodePort not found'
  [[ -n "$NODE_IP" ]] || fail 'Node IP not found'
  APP_URL="http://${NODE_IP}:${NODE_PORT}/"
  ENDPOINT="$APP_URL"
fi

retry 30 2 curl -fsS -H 'Host: app.mts-hack.local' "$APP_URL" -o "$TMP" \
  || fail 'Application is unavailable through Gateway API'
grep -q 'Hello from MTS ENGINEER HACK!' "$TMP" || fail 'Unexpected application response'

echo 'Gateway API: OK'
echo "Endpoint: ${ENDPOINT}"

echo
echo 'Prometheus targets:'
prometheus_target_ready() {
  kubectl -n monitoring exec deploy/prometheus -- \
    wget -qO- http://127.0.0.1:9090/api/v1/targets 2>/dev/null \
    | grep -q 'kube-state-metrics'
}
retry 30 2 prometheus_target_ready || fail 'kube-state-metrics target not found in Prometheus API'
echo 'Prometheus: kube-state-metrics target discovered'

echo
curl -fsS -H 'Host: app.mts-hack.local' "${APP_URL}log-check" >/dev/null

kubectl -n logging port-forward svc/opensearch 19200:9200 \
  >/tmp/mts-opensearch-pf.log 2>&1 &
cleanup_pids+=("$!")

retry 30 2 curl -fsS 'http://127.0.0.1:19200/_cluster/health' -o /dev/null \
  || { cat /tmp/mts-opensearch-pf.log >&2 || true; fail 'OpenSearch is unavailable'; }

log_is_indexed() {
  curl -fsS 'http://127.0.0.1:19200/fluentd-*/_search?q=log-check&pretty' 2>/dev/null \
    | grep -q 'log-check'
}
retry 30 2 log_is_indexed || fail 'log-check was not found in OpenSearch'
echo 'Logging: OK (Fluentd -> OpenSearch)'

echo
printf 'Smoke test passed.\n'
