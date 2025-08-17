# ДЗ №13 — Диагностика и отладка в Kubernetes

В рамках этого задания были выполнены задачи по отладке `distroless`-контейнера и ноды Kubernetes с использованием `kubectl debug` в локальном кластере Minikube.

## 1. Отладка Pod с помощью эфемерного контейнера

Был создан Pod `nginx-distroless` из `distroless`-образа. К нему был подключен отладочный контейнер `nicolaka/netshoot`.

**Команда для подключения:**
```bash
kubectl -n debug debug pod/nginx-distroless \
  -it \
  --image=nicolaka/netshoot \
  --container=debug-container \
  --target=nginx -- bash
```

### Доступ к файловой системе
При попытке получить доступ к `/etc/nginx` была получена ошибка, что подтверждает минималистичность `distroless`-образа и отсутствие стандартной файловой структуры Nginx.

**Результат:**
```
nginx-distroless:~# ls -la /etc/nginx
ls: /etc/nginx: No such file or directory
```

### Доступ к пространству имен PID
Опция `shareProcessNamespace: true` в спецификации Pod'а позволила увидеть процессы основного контейнера `nginx` из отладочного.

**Результат:**
```
nginx-distroless:~# ps aux | grep [n]ginx
    7 root      0:00 nginx: master process nginx -g daemon off;
   13 101       0:00 nginx: worker process
```

## 2. Перехват сетевого трафика с `tcpdump`

В отладочном контейнере был запущен `tcpdump` для прослушивания порта 80. Во время генерации трафика (`curl` из другого пода) были успешно перехвачены пакеты установки TCP-соединения и обмена HTTP-данными.

**Фрагмент вывода `tcpdump`:**
```
13:34:51.934980 eth0  In  ifindex 2 5e:9d:e0:cd:11:2b ethertype IPv4 (0x0800), length 80: 10.244.0.97.36522 > 10.244.0.96.80: Flags [S], seq 2531523348, win 64240, options [mss 1460,sackOK,TS val 3605548263 ecr 0,nop,wscale 7], length 0
13:34:51.935027 eth0  Out ifindex 2 02:0c:56:55:53:33 ethertype IPv4 (0x0800), length 80: 10.244.0.96.80 > 10.244.0.97.36522: Flags [S.], seq 1456111405, ack 2531523349, win 65160, options [mss 1460,sackOK,TS val 2246530373 ecr 3605548263,nop,wscale 7], length 0
13:34:51.935161 eth0  In  ifindex 2 5e:9d:e0:cd:11:2b ethertype IPv4 (0x0800), length 176: 10.244.0.97.36522 > 10.244.0.96.80: Flags [P.], seq 1:105, ack 1, win 502, options [nop,nop,TS val 3605548264 ecr 2246530373], length 104: HTTP: GET / HTTP/1.1
13:34:51.935278 eth0  Out ifindex 2 02:0c:56:55:53:33 ethertype IPv4 (0x0800), length 310: 10.244.0.96.80 > 10.244.0.97.36522: Flags [P.], seq 1:239, ack 105, win 509, options [nop,nop,TS val 2246530373 ecr 2246530373], length 238: HTTP: HTTP/1.1 200 OK
```

## 3. Отладка ноды и доступ к логам Pod'а

С помощью `kubectl debug node/minikube` был получен доступ к файловой системе ноды. После `chroot /host` удалось найти и прочитать лог-файлы контейнера `nginx` из директории `/var/log/pods/`.

**Команда для получения логов:**
```bash
# PUID взят из команды: kubectl -n debug get pod nginx-distroless -o jsonpath='{.metadata.uid}'
PUID=32398705-a1bf-47d7-b144-17b76dcf75e5
tail -n +1 /var/log/pods/debug_nginx-distroless_${PUID}/nginx/*.log | head -n 5
```

**Фрагмент логов:**
```json
{"log":"10.244.0.97 - - [17/Aug/2025:21:34:51 +0800] \"GET / HTTP/1.1\" 200 612 \"-\" \"curl/8.15.0\" \"-\"\n","stream":"stdout","time":"2025-8-17T13:34:51.935582955Z"}
{"log":"10.244.0.97 - - [17/Aug/2025:21:34:52 +0800] \"GET / HTTP/1.1\" 200 612 \"-\" \"curl/8.15.0\" \"-\"\n","stream":"stdout","time":"2025-8-17T13:34:52.942867102Z"}
```

## 4. Задание со *: трассировка системных вызовов с `strace`

Первоначальная попытка запуска `strace` завершилась ошибкой `Operation not permitted`. Это связано с `seccomp`-профилем по умолчанию в Kubernetes, который блокирует системный вызов `ptrace`.

Для решения проблемы был создан новый Pod (`pod-distroless-debug.yaml`), в котором:
1.  Отключен `seccomp`-профиль (`securityContext.seccompProfile.type: Unconfined`).
2.  Добавлен привилегированный **сайдкар-контейнер** `dbg` с необходимыми `capabilities` (`SYS_PTRACE`).

После этого `strace` был успешно подключен к мастер-процессу Nginx из сайдкар-контейнера.

**Команда для запуска `strace` (внутри сайдкара):**
```bash
PID=$(pidof nginx | awk "{print \$1}");
echo "Tracing PID=$PID";
strace -p "$PID" -f -tt -s 80
```

**Фрагмент вывода `strace`:**
```
13:46:51.496574 accept4(6, {sa_family=AF_INET, sin_port=htons(58344), sin_addr=inet_addr("10.244.0.99")}, [112 => 16], SOCK_NONBLOCK) = 3
13:46:51.497457 recvfrom(3, "GET / HTTP/1.1\r\nHost: nginx-distroless.debug.svc.cluster.local\r\nUser-Agent: curl"..., 1024, 0, NULL, NULL) = 104
13:46:51.497945 stat("/usr/share/nginx/html/index.html", {st_mode=S_IFREG|0644, st_size=612, ...}) = 0
13:46:51.498223 openat(AT_FDCWD, "/usr/share/nginx/html/index.html", O_RDONLY|O_NONBLOCK) = 11
13:46:51.498652 writev(3, [{iov_base="HTTP/1.1 200 OK\r\nServer: nginx/1.18.0\r\nDate: Sun, 17 Aug 2025 13:46:51 GMT\r\nCont"..., iov_len=238}], 1) = 238
13:46:51.498959 sendfile(3, 11, [0] => [612], 612) = 612
13:46:51.499233 write(5, "10.244.0.99 - - [17/Aug/2025:21:46:51 +0800] \"GET / HTTP/1.1\" 200 612 \"-\" \"curl/"..., 92) = 92
13:46:51.500378 close(3)                = 0
```