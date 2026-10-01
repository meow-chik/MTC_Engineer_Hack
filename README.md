# MTS ENGINEER HACK — Kubernetes / DevOps

Репродуцируемое решение кейса: Kubernetes + Gateway API + Prometheus + Fluentd + OpenSearch.

## Архитектура

```text
Client
  |
  | HTTP :30080 (NodePort)
  v
Envoy Gateway 1.9.2
  |
  | Gateway API: Gateway -> HTTPRoute
  v
Nginx 1.29-alpine
  |
  +--> stdout/stderr --> /var/log/containers/*.log --> Fluentd DaemonSet --> OpenSearch 3.9.0
  |
  +--> Kubernetes metrics (через kube-state-metrics) --> Prometheus 3.15.0
```

### Выбранные версии

| Компонент | Версия |
|---|---|
| OS | Ubuntu 24.04 LTS |
| Kubernetes | 1.36.5 |
| containerd | 2.x из Ubuntu repository |
| CNI | Flannel 0.27.4 |
| Gateway API implementation | Envoy Gateway 1.9.2 |
| Prometheus | 3.15.0 |
| kube-state-metrics | 2.20.0 |
| Fluentd Kubernetes DaemonSet | 1.19.3-1.1 |
| OpenSearch | 3.9.0 |
| Demo app | Nginx 1.29-alpine |

Версии Kubernetes и компонентов зафиксированы, чтобы повторный запуск не получил неожиданное обновление.

## Что реализовано

- Kubernetes-кластер, ориентированный на kubeadm и Ubuntu 24.04.
- Nginx как демонстрационное приложение; ответ `Hello from MTS ENGINEER HACK!`.
- Access/error logs Nginx идут в stdout/stderr и попадают в стандартные container logs Kubernetes.
- Envoy Gateway 1.9.2.
- GatewayClass, Gateway, HTTPRoute.
- Envoy Service переводится в NodePort, поэтому решение не требует cloud LoadBalancer.
- Prometheus 3.15.0 собирает метрики kube-state-metrics и собственные метрики.
- Fluentd собирает CRI/container logs со всех узлов и отправляет их в OpenSearch.
- OpenSearch используется как локальное хранилище логов для демонстрации.
- Idempotent deployment через shell-скрипты и `kubectl apply`.
- Smoke-тесты проверяют приложение, Gateway API, Prometheus target и наличие логов в OpenSearch.
- CI выполняет YAML validation и shellcheck.

## Требования к среде

Минимально рекомендуется для single-node demo:

- Ubuntu 24.04 LTS
- 4 vCPU
- 8 GB RAM
- 30 GB свободного диска
- root/sudo
- интернет-доступ к публичным container registries и GitHub releases

Решение также содержит конфигурацию kind для быстрого локального теста, но основной путь сдачи — kubeadm.

## 1. Подготовка Kubernetes через kubeadm

На чистой Ubuntu 24.04:

```bash
sudo ./cluster/kubeadm/install.sh
```

Скрипт:

1. отключает swap;
2. устанавливает containerd;
3. включает systemd cgroup driver;
4. устанавливает kubeadm/kubelet/kubectl 1.36.5;
5. выполняет `kubeadm init`;
6. устанавливает Flannel;
7. снимает control-plane taint для single-node demo;
8. настраивает kubeconfig текущего пользователя.

Если кластер уже создан, этот шаг можно пропустить.

## 2. Установка решения

```bash
./scripts/deploy.sh
```

Скрипт устанавливает Envoy Gateway, затем application, monitoring и logging stack.

Envoy Gateway ставится из фиксированного release `v1.9.2` через официальный `install.yaml`; Gateway API CRD входят в этот manifest.

## 3. Проверка приложения через Gateway API

```bash
./scripts/smoke-test.sh
```

Или вручную:

```bash
export ENVOY_SERVICE=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=public-gateway \
  -o jsonpath='{.items[0].metadata.name}')
export NODE_PORT=$(kubectl -n envoy-gateway-system get svc "$ENVOY_SERVICE" \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl -fsS -H 'Host: app.mts-hack.local' "http://${NODE_IP}:${NODE_PORT}/"
```

Ожидается:

```text
Hello from MTS ENGINEER HACK!
```

Для среды без возможности достучаться до NodePort снаружи можно использовать port-forward:

```bash
ENVOY_SERVICE=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=public-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway-system port-forward "svc/${ENVOY_SERVICE}" 8888:80
```

В другом терминале:

```bash
curl -fsS -H 'Host: app.mts-hack.local' http://127.0.0.1:8888/
```

## 4. Проверка Gateway API

```bash
kubectl get gatewayclass public-gateway
kubectl get gateway -n app public-gateway
kubectl get httproute -n app app-route
kubectl describe gateway -n app public-gateway
```

Ожидается `Accepted=True` и `Programmed=True` у Gateway.

## 5. Проверка Prometheus

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090
```

Откройте `http://127.0.0.1:9090` и выполните запрос:

```promql
kube_pod_info
```

Проверка target:

```bash
kubectl -n monitoring exec deploy/prometheus -- \
  wget -qO- http://127.0.0.1:9090/api/v1/targets
```

Цель `kube-state-metrics` должна иметь `health="up"`.

Дополнительные запросы:

```promql
count(kube_pod_info)
count(kube_deployment_status_replicas_available)
```

## 6. Проверка логирования Fluentd -> OpenSearch

Сначала создайте HTTP-запрос:

```bash
curl -fsS -H 'Host: app.mts-hack.local' "http://${NODE_IP}:${NODE_PORT}/log-check"
```

Проверьте Fluentd:

```bash
kubectl -n logging get pods -l app=fluentd
kubectl -n logging logs daemonset/fluentd --tail=100
```

Проверьте OpenSearch:

```bash
kubectl -n logging port-forward svc/opensearch 9200:9200
```

В другом терминале:

```bash
curl -fsS 'http://127.0.0.1:9200/_cat/indices?v'
curl -fsS 'http://127.0.0.1:9200/fluentd-*/_search?q=log-check&pretty'
```

В результате должна присутствовать запись access-log с URI `/log-check`.

## 7. Повторный запуск

```bash
./scripts/deploy.sh
./scripts/deploy.sh
```

Повторный запуск использует `kubectl apply`, поэтому не должен создавать дубликаты ресурсов или переводить систему в некорректное состояние.

## 8. CI/CD

GitHub Actions выполняет два автоматических контроля: Kubernetes YAML validation через kubeconform и ShellCheck для deploy/smoke/destroy scripts.

## 9. Удаление

```bash
./scripts/destroy.sh
```

Для полного удаления kubeadm-кластера:

```bash
sudo kubeadm reset -f
```

## Структура репозитория

```text
.
├── cluster/
│   ├── kubeadm/          # основной путь создания Kubernetes
│   └── kind/             # быстрый локальный тест
├── k8s/
│   ├── app/              # Nginx Deployment/Service/ConfigMap
│   ├── gateway/          # EnvoyProxy/GatewayClass/Gateway/HTTPRoute
│   ├── monitoring/       # Prometheus + kube-state-metrics
│   └── logging/          # Fluentd + OpenSearch
├── scripts/
│   ├── deploy.sh
│   ├── destroy.sh
│   └── smoke-test.sh
├── docs/
│   └── architecture.svg
├── .github/workflows/ci.yml
└── README.md
```

## Безопасность и ограничения

- Секреты и реальные credentials в репозитории отсутствуют.
- OpenSearch запускается без security plugin только для демонстрационного single-node стенда; в production необходимы TLS, authentication, persistent volumes и RBAC hardening.
- Prometheus использует `emptyDir`; для production следует использовать persistent storage и retention policy.
- Single-node kubeadm не является production HA-конфигурацией.
- NodePort выбран для воспроизводимости на bare-metal; в production можно заменить его на LoadBalancer/MetalLB.

## Дополнительные возможности

1. Gateway API использует отдельный `GatewayClass` с `EnvoyProxy` parametersRef.
2. Gateway работает через NodePort без зависимости от cloud provider.
3. `/healthz` и `/log-check` позволяют делать однозначные smoke-проверки.
4. CI проверяет Kubernetes YAML и shell scripts.
5. OpenSearch позволяет не только показать сбор логов, но и сделать запрос по конкретному HTTP URI.
