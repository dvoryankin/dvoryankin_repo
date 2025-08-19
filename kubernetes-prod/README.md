# ДЗ №14 — Подходы к развертыванию и обновлению production‑grade кластера

Выполнено на Yandex Cloud:

1) **Основное задание (kubeadm)** — кластер *1 master + 3 worker*, установка **и последующее обновление** с помощью `kubeadm`:
   - установка — скриптом `scripts/kubeadm-setup.sh`;
   - апгрейд до 1.31.x — скриптом `scripts/kubeadm-upgrade.sh` (master → workers по очереди).

2) **Задание со звёздочкой (kubespray)** — отказоустойчивый HA‑кластер *3 control‑plane + 2 worker* версии **v1.30.6** с CNI **Calico** и полной автоматизацией (создание ВМ, генерация inventory, запуск Kubespray).

---

## Структура репозитория (важные файлы)

```
kubernetes-prod/
├── cloud-init/node-init.yaml                      # cloud-init для ВМ (swap off, containerd, kube* 1.30 repo)
├── inventory/otus-ha/
│   ├── hosts.yaml                                 # Ansible inventory (генерируется скриптом)
│   └── group_vars/
│       ├── etcd/main.yml                          # настройки etcd (SAN и т.п.)
│       └── k8s_cluster/k8s-cluster.yml            # kube_version, calico
└── scripts/
    ├── provision_yc_vms.sh                        # создать/переиспользовать сеть и поднять 5 ВМ (3 CP + 2 W)
    ├── build_hosts_yaml_from_yc.sh                # собрать hosts.yaml из YC
    ├── kubespray_bootstrap_yaml.sh                # клонировать Kubespray и запустить развертывание
    ├── nuke_yc_vms.sh                             # удалить ВМ по inventory
    ├── kubeadm-setup.sh                           # (Часть 1) установка кластера kubeadm
    └── kubeadm-upgrade.sh                         # (Часть 1) апгрейд kubeadm‑кластера
```

---

# Часть 1 — kubeadm (основное задание)

### 1. Подготовка
- 4 ВМ (Ubuntu 22.04): **1 master + 3 worker**. Можно поднять вручную или любым способом.
- На узлах открыт доступ по SSH для пользователя `ubuntu` с ключом.

### 2. Установка
На **master**:
```bash
sudo bash kubernetes-prod/scripts/kubeadm-setup.sh master
```
Скрипт выведет `kubeadm join ...`. Сохраните команду.

На **каждом worker**:
```bash
sudo bash kubernetes-prod/scripts/kubeadm-setup.sh worker "kubeadm join <MASTER_IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
```

После установки:
```bash
kubectl get nodes -o wide
```

### 3. Обновление до 1.31.x
**Master:**
```bash
sudo bash kubernetes-prod/scripts/kubeadm-upgrade.sh master
```

**Workers (по одному):**
```bash
kubectl drain <worker-name> --ignore-daemonsets

# на самом worker
sudo bash kubernetes-prod/scripts/kubeadm-upgrade.sh worker

# обратно в строй
kubectl uncordon <worker-name>
```

Проверка:
```bash
kubectl get nodes -o wide
```

---

# Часть 2 — Kubespray (задание со звёздочкой)

## 0. Подготовка окружения
- Установлены: `yc`, `ansible`, `python3`, `git`.
- `yc init` выполнен и выбран нужный cloud/folder.
- В `~/.ssh/yc_k8s_key` — приватный ключ, а его `*.pub` уже прописан в `cloud-init/node-init.yaml` (секция `ssh-authorized-keys`).

> Скрипты не требуют `jq`/`yq`, всё делается средствами bash+python (стандартная библиотека).

## 1) Поднять ВМ (3×CP + 2×Worker)
Скрипт:
```bash
# при необходимости можно переопределить сеть/подсеть заранее:
# export NET=otus-k8s-network
# export SUBNET=otus-k8s-subnet

bash kubernetes-prod/scripts/provision_yc_vms.sh
```
Скрипт:
- при необходимости создаст (или переиспользует) сеть/подсеть;
- развернёт 5 ВМ `cp1,cp2,cp3,wk1,wk2` с `cloud-init`;
- корректно подберёт image‑id для семейства `ubuntu-2204-lts` из `standard-images`.

## 2) Сгенерировать inventory
```bash
bash kubernetes-prod/scripts/build_hosts_yaml_from_yc.sh
```
На выходе будет актуальный `kubernetes-prod/inventory/otus-ha/hosts.yaml` с внешними и внутренними адресами.

> При повторной генерации файл **перезаписывается**.

## 3) Запустить Kubespray
```bash
bash kubernetes-prod/scripts/kubespray_bootstrap_yaml.sh
```
Скрипт:
- клонирует Kubespray (`release-2.26`),
- создаёт виртуальное окружение,
- копирует инвентарь и `group_vars`,
- запускает `ansible-playbook cluster.yml`.

Версия Kubernetes задаётся в `inventory/otus-ha/group_vars/k8s_cluster/k8s-cluster.yml` (по умолчанию **v1.30.6**), CNI — **Calico**.

## 4) Доступ к кластеру с локальной машины
Вариант A — через SSH‑туннель к `cp1`:

```bash
# скопировать kubeconfig
ansible -i kubernetes-prod/inventory/otus-ha/hosts.yaml cp1 -b \
  -m fetch -a 'src=/etc/kubernetes/admin.conf dest=~/.kube/otus-ha.conf flat=yes'

# правим адрес на localhost (туннель)
sed -i -E 's#server:\s*https://[^:]+:6443#server: https://127.0.0.1:6443#' ~/.kube/otus-ha.conf
export KUBECONFIG=~/.kube/otus-ha.conf

# открыть туннель на API‑server cp1 (внутренний 6443)
ssh -i ~/.ssh/yc_k8s_key -fNT \
  -L 6443:<INTERNAL_IP_CP1>:6443 \
  ubuntu@<EXTERNAL_IP_CP1>

# проверить
kubectl cluster-info
kubectl get nodes -o wide
```

> Если порт был занят: `pkill -f 'ssh.*-L .*:6443'` и повторить туннель.

Вариант B — выполнять `kubectl` по SSH непосредственно на `cp1`.

## 5) Диагностика / Проверки
- Ноды:
  ```bash
  kubectl get nodes -o wide
  ```
- Системные поды:
  ```bash
  kubectl -n kube-system get pods -o wide
  ```
- Calico:
  ```bash
  kubectl -n kube-system rollout status ds/calico-node --timeout=120s
  ```
- etcd (с контрол‑плейна):
  ```bash
  ETCDCTL_API=3 /usr/local/bin/etcdctl \
    --endpoints=https://<cp1_ip>:2379,https://<cp2_ip>:2379,https://<cp3_ip>:2379 \
    --cacert=/etc/ssl/etcd/ssl/ca.pem \
    --cert=/etc/ssl/etcd/ssl/admin-$(hostname -s).pem \
    --key=/etc/ssl/etcd/ssl/admin-$(hostname -s)-key.pem \
    endpoint status -w table
  ```

> Пример итогового статуса из моего запуска:
>
> ```
> NAME   STATUS   ROLES           AGE   VERSION   INTERNAL-IP
> cp1    Ready    control-plane   21m   v1.30.6   10.10.0.23
> cp2    Ready    control-plane   21m   v1.30.6   10.10.0.34
> cp3    Ready    control-plane   19m   v1.30.6   10.10.0.12
> wk1    Ready    <none>          19m   v1.30.6   10.10.0.4
> wk2    Ready    <none>          19m   v1.30.6   10.10.0.25
> ```

---

## Очистка
Удалить созданные ВМ по текущему `hosts.yaml`:
```bash
bash kubernetes-prod/scripts/nuke_yc_vms.sh
```
> Сеть/подсеть скрипт **не удаляет**. При необходимости можно удалить их руками через `yc vpc ...`

---
