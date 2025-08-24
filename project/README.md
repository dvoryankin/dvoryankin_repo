# Managed K8s: Online Boutique (Ingress, Monitoring, Logging, CI/CD)

MVP‑платформа на Kubernetes (YC Managed Kubernetes): публичный **ingress + nip.io**, мониторинг (**kube‑prometheus‑stack** с алертами), логирование (**Loki + Promtail**), и **CI/CD на GitHub Actions** для сборки/раскатки `frontend` из Google **Online Boutique**.

---

## Содержание
- [Требования и входные данные](#требования-и-входные-данные)
- [Быстрый старт (последовательность)](#быстрый-старт-последовательность)
- [Ingress и домен](#ingress-и-домен)
- [Деплой приложения](#деплой-приложения)
- [Мониторинг (Prometheus/Grafana/Alerts)](#мониторинг-prometheusgrafanaalerts)
- [Логи (Loki/Promtail)](#логи-lokipromtail)
- [CI/CD (GitHub Actions + GHCR)](#cicd-github-actions--ghcr)
- [Проверки (cheat‑sheet)](#проверки-cheat-sheet)
- [Очистка](#очистка)
- [Структура репозитория](#структура-репозитория)
- [Скриншоты для приёмки](#скриншоты-для-приёмки)
- [FAQ / Траблшутинг](#faq--траблшутинг)

---

## Требования и входные данные

- **Kubernetes**: Managed‑кластер в Яндекс.Облаке (YC).
- **Публичный IP** у `ingress-nginx` и домен вида `shop.<EXTERNAL-IP>.nip.io`.
- **Репозиторий GitHub** (публичный) с включёнными GitHub Actions.

> Все скрипты запускаются из каталога **`project/`** репозитория.

---

## Быстрый старт

```bash
# 0) (опционально) создать кластер и сеть в YC
cd project/infra/yc
./create.sh
./nat.sh
yc managed-kubernetes cluster get-credentials demo-cluster --external --force

# 1) RBAC + ServiceAccount для CI/CD и kubeconfig для Actions
cd project
kubectl apply -f infra/k8s/ci/rbac.yaml
./infra/k8s/ci/kubeconfig-from-sa.sh
# в Settings → Actions → Secrets добавьте секрет KUBECONFIG_B64 из файла kubeconfig.ci.b64

# 2) Ingress controller (+LB IP)
cd project && ./scripts/01_install_ingress.sh

# 3) Приложение Online Boutique + Ingress на shop.<IP>.nip.io
./scripts/02_deploy_app.sh

# 4) Мониторинг (Prometheus/Grafana/Alertmanager)
./scripts/03_install_monitoring.sh

# 5) Логи (Loki + Promtail) + автопровижининг Loki‑datasource в Grafana
./scripts/04_install_logging.sh
```

Открой:
- Магазин: `http://shop.<EXTERNAL-IP>.nip.io`
- Prometheus: `kubectl -n observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090`
- Grafana: `kubectl -n observability port-forward deploy/kps-grafana 3000:3000` → http://localhost:3000 (admin / **admin123**).

---

## Ingress и домен

Скрипт `scripts/01_install_ingress.sh` ставит **ingress-nginx** (Helm) и включает метрики.
После установки получи внешний IP (используется `nip.io`):

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
# Хост фронта: shop.<IP>.nip.io
```

---

## Деплой приложения

Скрипт `scripts/02_deploy_app.sh`:
1. Применяет манифесты Online Boutique (v0.8.0).
2. Рендерит `apps/online-boutique/ingress.yaml.tmpl` в `apps/online-boutique/ingress.yaml`
   с хостом `shop.<EXTERNAL-IP>.nip.io` и применяет его.
3. Ждёт готовности `deploy/frontend`.

Проверка:
```bash
kubectl -n default rollout status deploy/frontend --timeout=180s
kubectl -n default get ingress
```

---

## Мониторинг (Prometheus/Grafana/Alerts)

Скрипт `scripts/03_install_monitoring.sh` ставит **kube‑prometheus‑stack** в ns `observability`
с твиками Grafana (права/инициализация) и отдельным алертом на высокий уровень 5xx по Ingress:
`platform/monitoring/alerts/ingress-5xx.yaml`.

Полезное:
```bash
# Prometheus Targets (должны быть зелёные)
kubectl -n observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090

# Пароль Grafana из секрета
kubectl -n observability get secret kps-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

---

## Логи (Loki/Promtail)

Скрипт `scripts/04_install_logging.sh` ставит **loki‑stack** (включён promtail) и
добавляет **Grafana datasource** для Loki через ConfigMap.

Проверка:
```bash
kubectl -n observability get pods -l app.kubernetes.io/name=promtail -o wide
kubectl -n observability get pod loki-0
```

В Grafana → **Explore**:
```logql
{namespace="default", container="server"}
```

---

## CI/CD (GitHub Actions + GHCR)

Ветка `main` (и `project/managed-shop-otus`) триггерит **build → deploy**.

### Что делает pipeline
- **Build**: собирает `project/src/frontend/Dockerfile` (база: `gcr.io/google-samples/...:v0.8.0`),
  пушит в GHCR два тега:
    - `ghcr.io/<owner>/dvoryankin_repo/frontend:<full-sha>`
    - `ghcr.io/<owner>/dvoryankin_repo/frontend:latest`
- **Deploy**: пишет kubeconfig из секрета `KUBECONFIG_B64` и исполняет:
  ```bash
  kubectl -n default set image deploy/frontend server="${IMAGE}:${TAG}"
  kubectl -n default rollout status deploy/frontend --timeout=180s
  ```

### Настройки репозитория
- **Settings → Actions → General → Workflow permissions**: **Read and write permissions**.
- **GHCR пакет** `dvoryankin_repo/frontend` переведён в **Public** → **imagePullSecrets не требуются**.

> Если пакет приватный, то создать `imagePullSecret` и пропатчить `ServiceAccount`:
> ```bash
> kubectl -n default create secret docker-registry ghcr-creds \
>   --docker-server=ghcr.io \
>   --docker-username="<github_user>" \
>   --docker-password="<PAT с write:packages>" \
>   --docker-email="you@example.com"
> kubectl -n default patch sa default -p '{"imagePullSecrets":[{"name":"ghcr-creds"}]}'
> ```

### Секреты Actions
- `KUBECONFIG_B64` — из `project/infra/k8s/ci/kubeconfig-from-sa.sh` (см. быстрый старт).

---

## Проверки (cheat‑sheet)

```bash
# 1) Ingress IP и домен
IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
   -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo $IP
echo "http://shop.${IP}.nip.io"

# 2) Frontend: образ и готовность
kubectl -n default describe deploy/frontend | grep -i "Image:"
kubectl -n default rollout status deploy/frontend --timeout=180s
kubectl -n default logs deploy/frontend --tail=100

# 3) Мониторинг
kubectl -n observability get pods -l "app.kubernetes.io/name=grafana"
kubectl -n observability get pods -l "app.kubernetes.io/name=prometheus"

# 4) Логи
kubectl -n observability get pods -l "app.kubernetes.io/name=promtail" -o wide
kubectl -n observability logs ds/loki-promtail -c promtail --tail=50
```

---

## Очистка

```bash
cd project
./scripts/90_cleanup.sh

# (опционально) снести облако
./scripts/99_cleanup_cloud.sh
# или минимальный вариант
cd infra/yc && ./cleanup.sh
```

---

## Структура репозитория

```
project/
├─ apps/
│  └─ online-boutique/
│     └─ ingress.yaml.tmpl                # шаблон Ingress для фронта
├─ infra/
│  └─ k8s/
│     └─ ci/
│        ├─ rbac.yaml                     # NS=cicd, SA, Role(+Binding) для деплоя в default
│        └─ kubeconfig-from-sa.sh         # генерит kubeconfig.ci(.b64) из SA‑токена
│
├─ platform/
│  ├─ ingress/values.yaml                 # ingress-nginx (LB + metrics + ServiceMonitor)
│  ├─ logging/
│  │  ├─ values.yaml                      # loki-stack (вкл. promtail)
│  │  └─ grafana-datasource-loki.yaml     # datasource для Grafana
│  └─ monitoring/
│     ├─ values.yaml                      # kube-prometheus-stack overrides
│     └─ alerts/ingress-5xx.yaml          # custom alert
│
├─ scripts/
│  ├─ 01_install_ingress.sh
│  ├─ 02_deploy_app.sh
│  ├─ 03_install_monitoring.sh
│  ├─ 04_install_logging.sh
│  ├─ 90_cleanup.sh
│  └─ 99_cleanup_cloud.sh
└─ src/
   └─ frontend/Dockerfile                 # образ для CI
```

---

## Скрины

1. **GitHub Actions** — зелёный ран с шагами **Build** и **Set image & rollout**.
2. **GHCR** — пакет `dvoryankin_repo/frontend` с последним тегом (`latest` и `<sha>`).
3. **kubectl get ingress** — домен `shop.<IP>.nip.io`.
4. **kubectl describe deploy/frontend | Image** — применён ваш образ из GHCR.
5. **Prometheus /targets** — все цели зелёные.
6. **Grafana → Explore (Loki)** — логи контейнера `server` (`namespace="default"`).
7. (Опционально) Дашборд/график по Ingress 5xx (если включали).

Скрины в `project/docs/`

---

## FAQ / Траблшутинг

**GHCR: 403 при pull**  
Сделать пакет публичным **или** подключить `imagePullSecret` и пропатчить `ServiceAccount` (см. CI/CD раздел).

**Rollout завис на “1 old replicas pending termination”**  
Проверить новый Pod:
```bash
kubectl -n default get pods -l app=frontend -o wide
kubectl -n default describe pod <pod>
# несколько раз был ImagePullBackOff → проблема доступа к образу GHCR
```

**Grafana не видит Loki**  
Проверить `grafana-datasource-loki.yaml` применён и поднимается `kps-grafana`. Перезапустить Grafana:
```bash
kubectl -n observability rollout restart deploy/kps-grafana
```

**Promtail на containerd‑нодах**  
Убедиться, что в `platform/logging/values.yaml` настроены пути `/var/log/pods` и `/var/log/containers`.
Если нет Docker — убрать `/var/lib/docker/containers`.

**Kubeconfig для Actions**  
Всегда обновлять секрет `KUBECONFIG_B64` при смене кластера/SA. Проверка локально:
```bash
KUBECONFIG=project/infra/k8s/ci/kubeconfig.ci kubectl auth can-i patch deploy/frontend -n default
# должно быть "yes"
```
