# MTS ENGINEER HACK — Kubernetes / DevOps

Воспроизводимое решение DevOps-кейса: Kubernetes, Gateway API, мониторинг Prometheus и централизованный сбор логов Fluentd -> OpenSearch.

## Архитектура

```text
Client
  |
  | HTTP :30080 (NodePort)
  v
Envoy Gateway 1.9.2
  |
  | Gateway API: GatewayClass -> Gateway -> HTTPRoute
  v
Service web
  |
  v
Nginx 1.29-alpine (2 replicas)
  |
  +--> stdout/stderr --> /var/log/containers/*.log --> Fluentd DaemonSet --> OpenSearch 3.9.0
  |
  +--> Kubernetes state --> kube-state-metrics 2.20.0 --> Prometheus 3.15.0
```

Основной сценарий развёртывания рассчитан на Ubuntu 24.04 LTS и Kubernetes, созданный через kubeadm. Для локальной и CI-проверки также предусмотрен kind.

## Используемые технологии и версии

| Компонент | Версия / вариант |
|---|---|
| ОС | Ubuntu 24.04 LTS |
| Kubernetes | 1.36.5 |
| Способ создания основного кластера | kubeadm |
| Container runtime | containerd 2.x из Ubuntu repository |
| CNI | Flannel 0.27.4 |
| Gateway API implementation | Envoy Gateway 1.9.2 |
| Демонстрационное приложение | Nginx 1.29-alpine |
| Prometheus | 3.15.0 |
| kube-state-metrics | 2.20.0 |
| Fluentd Kubernetes DaemonSet | 1.19.3-1.1 |
| Хранилище логов | OpenSearch 3.9.0 |
| CI | GitHub Actions |
| Валидация manifests | kubeconform |
| Проверка shell-скриптов | ShellCheck |

Версии ключевых компонентов зафиксированы, чтобы повторный запуск не зависел от неожиданных обновлений.

## Что реализовано

- single-node Kubernetes-кластер через kubeadm для Ubuntu 24.04;
- дополнительный kind-кластер для CI и быстрой локальной проверки;
- Nginx с двумя репликами и однозначным HTTP-ответом `Hello from MTS ENGINEER HACK!`;
- readiness/liveness probes и resource requests/limits;
- access/error logs Nginx в stdout/stderr;
- Envoy Gateway и ресурсы Gateway API: `GatewayClass`, `Gateway`, `HTTPRoute`;
- публикация Gateway через NodePort без зависимости от облачного LoadBalancer;
- Prometheus и kube-state-metrics;
- Fluentd как DaemonSet для чтения CRI/container logs;
- OpenSearch как централизованное хранилище логов;
- повторяемый deploy через shell-скрипты и `kubectl apply`;
- smoke-тесты приложения, Gateway API, мониторинга и логирования;
- GitHub Actions с validation и integration jobs;
- диагностический вывод состояния pods/events/logs при падении integration job.

## Требования к среде

Для основного single-node стенда рекомендуется:

- Ubuntu 24.04 LTS;
- 4 vCPU;
- 8 GB RAM;
- 30 GB свободного места;
- root/sudo;
- доступ в интернет к публичным container registries и GitHub releases.

## Структура репозитория

```text
.
├── cluster/
│   ├── kubeadm/
│   │   └── install.sh       # создание Kubernetes на Ubuntu 24.04
│   └── kind/
│       └── kind.yaml        # локальный/CI кластер
├── k8s/
│   ├── app/                 # Nginx Deployment, Service, ConfigMap
│   ├── gateway/             # EnvoyProxy, GatewayClass, Gateway, HTTPRoute
│   ├── monitoring/          # Prometheus + kube-state-metrics
│   └── logging/             # Fluentd + OpenSearch
├── scripts/
│   ├── deploy.sh            # развёртывание решения
│   ├── smoke-test.sh        # автоматическая проверка
│   └── destroy.sh           # удаление компонентов
├── docs/
│   └── architecture.svg
├── .github/workflows/
│   └── ci.yml
├── Makefile
└── README.md
```

## Быстрый запуск

### 1. Клонировать репозиторий

```bash
git clone https://github.com/meow-chik/MTC_Engineer_Hack.git
cd MTC_Engineer_Hack
```

### 2. Создать Kubernetes через kubeadm

На чистой Ubuntu 24.04:

```bash
sudo ./cluster/kubeadm/install.sh
```

Скрипт автоматически:

1. отключает swap;
2. загружает необходимые kernel modules;
3. настраивает sysctl для Kubernetes;
4. устанавливает и настраивает containerd;
5. устанавливает kubeadm/kubelet/kubectl 1.36.5;
6. выполняет `kubeadm init`;
7. устанавливает Flannel 0.27.4;
8. снимает control-plane taint для single-node стенда;
9. настраивает kubeconfig.

Проверка:

```bash
kubectl get nodes -o wide
```

Узел должен иметь статус `Ready`.

> Если Kubernetes-кластер уже существует, этап kubeadm можно пропустить.

## Развёртывание решения

```bash
./scripts/deploy.sh
```

или через Makefile:

```bash
make deploy
```

Deploy-скрипт устанавливает Envoy Gateway, затем применяет manifests приложения, Gateway API, мониторинга и логирования и ожидает готовности основных компонентов.

Проверка состояния:

```bash
kubectl get pods -A
```

Основные pods должны перейти в `Running`/`Ready`.

## Проверка приложения через Gateway API

Самый быстрый вариант:

```bash
./scripts/smoke-test.sh
```

Ручная проверка:

```bash
export ENVOY_SERVICE=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=public-gateway \
  -o jsonpath='{.items[0].metadata.name}')

export NODE_PORT=$(kubectl -n envoy-gateway-system get svc "$ENVOY_SERVICE" \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')

export NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl -fsS -H 'Host: app.mts-hack.local' \
  "http://${NODE_IP}:${NODE_PORT}/"
```

Ожидаемый ответ:

```text
Hello from MTS ENGINEER HACK!
```

Если NodePort недоступен напрямую из клиентской среды, можно использовать port-forward:

```bash
kubectl -n envoy-gateway-system port-forward \
  "svc/${ENVOY_SERVICE}" 8888:80
```

Во втором терминале:

```bash
curl -fsS -H 'Host: app.mts-hack.local' http://127.0.0.1:8888/
```

## Проверка Gateway API

```bash
kubectl get gatewayclass public-gateway
kubectl get gateway -n app public-gateway
kubectl get httproute -n app app-route
kubectl describe gateway -n app public-gateway
```

У Gateway ожидаются условия:

```text
Accepted=True
Programmed=True
```

HTTPRoute должен быть привязан к `public-gateway` и направлять трафик на Service `web`.

## Проверка мониторинга

Prometheus получает собственные метрики и Kubernetes state metrics от kube-state-metrics.

Запустить port-forward:

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090
```

Открыть:

```text
http://127.0.0.1:9090
```

Пример PromQL-запроса:

```promql
kube_pod_info
```

Дополнительные запросы:

```promql
count(kube_pod_info)
count(kube_deployment_status_replicas_available)
```

Проверка targets из командной строки:

```bash
kubectl -n monitoring exec deploy/prometheus -- \
  wget -qO- http://127.0.0.1:9090/api/v1/targets
```

Target `kube-state-metrics` должен иметь состояние `health="up"`.

## Проверка логирования

Nginx пишет access/error logs в stdout/stderr. Container runtime сохраняет их в стандартные Kubernetes container logs, Fluentd читает `/var/log/containers/*.log`, добавляет Kubernetes metadata и отправляет записи в OpenSearch.

Сначала создать проверочный HTTP-запрос:

```bash
curl -fsS -H 'Host: app.mts-hack.local' \
  "http://${NODE_IP}:${NODE_PORT}/log-check"
```

Проверить Fluentd:

```bash
kubectl -n logging get pods -l app=fluentd
kubectl -n logging logs daemonset/fluentd --tail=100
```

Открыть доступ к OpenSearch:

```bash
kubectl -n logging port-forward svc/opensearch 9200:9200
```

Во втором терминале:

```bash
curl -fsS 'http://127.0.0.1:9200/_cat/indices?v'
curl -fsS 'http://127.0.0.1:9200/fluentd-*/_search?q=log-check&pretty'
```

В результатах должна присутствовать access-log запись с URI `/log-check`.

## Повторный запуск и идемпотентность

```bash
./scripts/deploy.sh
./scripts/deploy.sh
```

Kubernetes-ресурсы применяются через `kubectl apply`, поэтому повторный запуск не должен создавать дубликаты или переводить систему в некорректное состояние.

## CI/CD

GitHub Actions запускается на `push`, `pull_request` и вручную через `workflow_dispatch`.

Pipeline содержит два основных этапа:

1. **validate**
   - проверка Kubernetes manifests через kubeconform;
   - проверка shell-скриптов через ShellCheck.

2. **integration**
   - создание временного Kubernetes-кластера kind;
   - развёртывание полного stack через `scripts/deploy.sh`;
   - запуск `scripts/smoke-test.sh`;
   - при ошибке — вывод pods, events и логов ключевых компонентов.

Таким образом CI проверяет не только синтаксис конфигурации, но и фактическое развёртывание решения.

## Локальное тестирование через kind

Для быстрой проверки без kubeadm можно создать kind-кластер с конфигурацией:

```bash
kind create cluster --config cluster/kind/kind.yaml
./scripts/deploy.sh
./scripts/smoke-test.sh
```

Этот путь используется прежде всего для разработки и CI. Основной сценарий сдачи — kubeadm на Ubuntu 24.04.

## Удаление

Удалить развёрнутые компоненты:

```bash
./scripts/destroy.sh
```

или:

```bash
make destroy
```

Полностью сбросить kubeadm-кластер:

```bash
sudo kubeadm reset -f
```

## Безопасность

- в репозитории отсутствуют реальные пароли, API-токены и приватные ключи;
- приложение запускается с ограниченными Linux capabilities и `allowPrivilegeEscalation: false`;
- используются readiness/liveness probes;
- для workload заданы requests/limits ресурсов;
- Fluentd использует отдельный ServiceAccount и RBAC;
- внешние компоненты используют публичные container images и фиксированные версии.

## Известные ограничения

- single-node kubeadm предназначен для демонстрации и не является HA production-конфигурацией;
- NodePort выбран для независимости от cloud provider; в production можно использовать LoadBalancer или MetalLB;
- OpenSearch запускается без security plugin для упрощения демонстрационного стенда; в production необходимы TLS, authentication и более строгая security-конфигурация;
- Prometheus использует `emptyDir`, поэтому его локальные данные не сохраняются после пересоздания Pod;
- OpenSearch развёрнут в single-node режиме;
- CI-кластер kind существует только во время выполнения GitHub Actions job.

## Дополнительные возможности

- отдельный `GatewayClass` с `EnvoyProxy` parametersRef;
- Gateway API без зависимости от коммерческого облака;
- две реплики приложения;
- `/healthz` для readiness/liveness и smoke-проверок;
- `/log-check` для однозначной проверки централизованного логирования;
- централизованный поиск логов через OpenSearch;
- GitHub Actions validation + полноценный integration deploy;
- автоматический diagnostic dump при ошибке CI.

## Критерий успешной проверки

Решение считается корректно развернутым, если одновременно выполняются следующие условия:

```bash
kubectl get nodes
kubectl get pods -A
kubectl get gateway -n app
kubectl get httproute -n app
./scripts/smoke-test.sh
```

И smoke-тест подтверждает:

- HTTP-запрос через Gateway API возвращает ожидаемый ответ;
- Gateway имеет корректные статусы;
- Prometheus видит target kube-state-metrics;
- запрос `/log-check` появляется в OpenSearch.
