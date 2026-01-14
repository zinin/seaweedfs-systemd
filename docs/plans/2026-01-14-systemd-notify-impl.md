# Systemd Notify Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Переключить seaweedfs@.service на Type=notify чтобы зависимые сервисы (nginx, dovecot, exim4) ждали реальной готовности mount.

**Architecture:** Скрипт seaweedfs-service.sh запускает weed в фоне, ждёт готовности (mountpoint -q для mount, 3 секунды для остальных), отправляет systemd-notify --ready, затем блокируется на wait. Сигналы SIGTERM/SIGINT передаются в weed для graceful shutdown.

**Tech Stack:** Bash, systemd, systemd-notify

---

## Task 1: Изменить seaweedfs@.service

**Files:**
- Modify: `dist/seaweedfs@.service`

**Step 1: Обновить секцию [Service]**

Открыть `dist/seaweedfs@.service` и заменить содержимое на:

```ini
[Unit]
Description=SeaweedFS Service (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=all
User=root
Group=root
ExecStart=/opt/seaweedfs/seaweedfs-service.sh %i
Restart=always
RestartSec=5s
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
```

Изменения:
- `Type=simple` → `Type=notify`
- Добавлен `NotifyAccess=all`
- Добавлен `TimeoutStartSec=60`

**Step 2: Commit**

```bash
git add dist/seaweedfs@.service
git commit -m "feat(systemd): switch to Type=notify for ready signaling"
```

---

## Task 2: Добавить функцию получения mount dir

**Files:**
- Modify: `dist/seaweedfs-service.sh:80-85`

**Step 1: Добавить функцию get_mount_dir после build_args**

После функции `build_args()` (строка 79) добавить:

```bash
# Get mount directory for mount service type
get_mount_dir() {
    xmlstarlet sel -N x="http://zinin.ru/xml/ns/seaweedfs-systemd" \
        -t -v "//x:service[x:id='$SERVICE_ID']/x:mount-args/x:dir" "$CONFIG_PATH"
}
```

**Step 2: Commit**

```bash
git add dist/seaweedfs-service.sh
git commit -m "feat(service): add get_mount_dir function"
```

---

## Task 3: Добавить функцию wait_for_ready

**Files:**
- Modify: `dist/seaweedfs-service.sh`

**Step 1: Добавить функцию wait_for_ready после get_mount_dir**

```bash
# Wait for service to be ready and send systemd notification
wait_for_ready() {
    local pid=$1
    local service_type=$2

    # Check that process started successfully
    sleep 0.5
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Error: weed process died immediately"
        exit 1
    fi

    if [[ "$service_type" == "mount" ]]; then
        local mount_dir
        mount_dir=$(get_mount_dir)

        if [[ -z "$mount_dir" ]]; then
            echo "Error: mount dir not found in config"
            kill "$pid" 2>/dev/null
            exit 1
        fi

        echo "Waiting for mount point: $mount_dir"
        for i in {1..30}; do
            if mountpoint -q "$mount_dir"; then
                echo "Mount point ready after ${i}s"
                systemd-notify --ready
                return 0
            fi
            sleep 1
        done

        echo "Error: mount point $mount_dir not ready after 30s"
        kill "$pid" 2>/dev/null
        exit 1
    else
        # For other service types, wait 3 seconds
        sleep 3
        systemd-notify --ready
    fi
}
```

**Step 2: Commit**

```bash
git add dist/seaweedfs-service.sh
git commit -m "feat(service): add wait_for_ready function with notify"
```

---

## Task 4: Добавить функцию run_weed

**Files:**
- Modify: `dist/seaweedfs-service.sh`

**Step 1: Добавить функцию run_weed после wait_for_ready**

```bash
# Run weed binary with proper signal handling
run_weed() {
    local weed_cmd=$1

    # Start weed in background
    eval "$weed_cmd" &
    WEED_PID=$!

    # Setup signal handler for graceful shutdown
    trap 'echo "Received signal, stopping weed..."; kill $WEED_PID 2>/dev/null; wait $WEED_PID; exit $?' SIGTERM SIGINT

    # Wait for ready and notify systemd
    wait_for_ready "$WEED_PID" "$SERVICE_TYPE"

    # Wait for weed to exit
    wait $WEED_PID
}
```

**Step 2: Commit**

```bash
git add dist/seaweedfs-service.sh
git commit -m "feat(service): add run_weed function with signal handling"
```

---

## Task 5: Заменить exec на run_weed

**Files:**
- Modify: `dist/seaweedfs-service.sh:166-186`

**Step 1: Заменить блок выполнения команды**

Заменить строки 166-186 (от "Show the command" до конца файла) на:

```bash
# Build the full command
if [ -n "$RUN_USER" ] && [ -n "$RUN_GROUP" ]; then
    if [ -n "$RUN_DIR" ]; then
        WEED_CMD="sudo -u '$RUN_USER' -g '$RUN_GROUP' bash -c \"cd '$RUN_DIR' && $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS\""
    else
        WEED_CMD="sudo -u '$RUN_USER' -g '$RUN_GROUP' $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS"
    fi
else
    if [ -n "$RUN_DIR" ]; then
        WEED_CMD="bash -c \"cd '$RUN_DIR' && $WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS\""
    else
        WEED_CMD="$WEED_BINARY $GLOBAL_ARGS $SERVICE_TYPE $ARGS"
    fi
fi

echo "Executing: $WEED_CMD"

# Run weed with notify support
run_weed "$WEED_CMD"
```

**Step 2: Commit**

```bash
git add dist/seaweedfs-service.sh
git commit -m "feat(service): replace exec with run_weed for notify support"
```

---

## Task 6: Тестирование на сервере

**Step 1: Скопировать файлы на сервер**

```bash
scp dist/seaweedfs@.service dist/seaweedfs-service.sh root@server:/opt/seaweedfs/
```

**Step 2: Перезагрузить systemd**

```bash
ssh root@server "systemctl daemon-reload"
```

**Step 3: Тест 1 — Проверить notify для mount**

```bash
ssh root@server "systemctl stop seaweedfs@zinin-mount nginx; systemctl start seaweedfs@zinin-mount; systemctl status seaweedfs@zinin-mount"
```

Ожидаемый результат: статус `active (running)`, в логах видно "Mount point ready after Ns"

**Step 4: Тест 2 — Проверить что nginx ждёт mount**

```bash
ssh root@server "systemctl stop seaweedfs@zinin-mount nginx; systemctl start nginx; systemctl status nginx seaweedfs@zinin-mount"
```

Ожидаемый результат: оба сервиса `active (running)`, mount запустился автоматически перед nginx

**Step 5: Тест 3 — Проверить graceful shutdown**

```bash
ssh root@server "systemctl stop seaweedfs@zinin-mount"
```

Ожидаемый результат: nginx и другие зависимые сервисы остановились, в логах mount видно "Received signal, stopping weed..."

---

## Финальная структура seaweedfs-service.sh

После всех изменений скрипт будет иметь такую структуру:

```
1-57:    Проверки (xmlstarlet, xmllint, config, schema, weed binary)
58-64:   Получение SERVICE_TYPE
66-68:   Получение RUN_USER, RUN_GROUP
70-79:   build_args()
80-83:   get_mount_dir()           # NEW
84-115:  wait_for_ready()          # NEW
116-130: run_weed()                # NEW
131-164: case для ARGS
165-185: Сборка команды и run_weed # MODIFIED (было exec)
```
