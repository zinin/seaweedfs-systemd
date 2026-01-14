# Systemd Notify для SeaweedFS Services

## Проблема

Сервисы, зависящие от SeaweedFS mount (nginx, dovecot, exim4), падают при старте, потому что systemd считает mount-сервис готовым сразу после запуска процесса (`Type=simple`), не дожидаясь реального монтирования файловой системы.

## Решение

Перевести `seaweedfs@.service` на `Type=notify`. Скрипт `seaweedfs-service.sh` будет сообщать systemd о готовности через `systemd-notify --ready`:
- Для `mount` — после успешной проверки `mountpoint -q`
- Для остальных типов — через 3 секунды после старта

## Изменения в seaweedfs@.service

**Файл:** `dist/seaweedfs@.service`

**Было:**
```ini
[Service]
Type=simple
User=root
Group=root
ExecStart=/opt/seaweedfs/seaweedfs-service.sh %i
Restart=always
RestartSec=5s
```

**Станет:**
```ini
[Service]
Type=notify
NotifyAccess=all
User=root
Group=root
ExecStart=/opt/seaweedfs/seaweedfs-service.sh %i
Restart=always
RestartSec=5s
TimeoutStartSec=60
```

- `Type=notify` — systemd ждёт сигнала готовности
- `NotifyAccess=all` — разрешает notify из скрипта (не только из основного процесса)
- `TimeoutStartSec=60` — даём запас сверх 30 секунд ожидания mount

## Изменения в seaweedfs-service.sh

**Файл:** `dist/seaweedfs-service.sh`

**Новая логика запуска:**

```bash
# Определяем команду weed и аргументы (существующая логика)
WEED_CMD="weed $SERVICE_TYPE $ARGS"

# Получаем mount dir для типа mount
MOUNT_DIR=$(xmlstarlet ... //mount-args/dir ...)

# Запускаем weed в фоне
$WEED_CMD &
WEED_PID=$!

# Проверяем что процесс запустился
sleep 0.5
if ! kill -0 $WEED_PID 2>/dev/null; then
    echo "Error: weed process died immediately"
    exit 1
fi

# Ожидание готовности
if [[ "$SERVICE_TYPE" == "mount" ]]; then
    # Ждём появления mount point (макс 30 сек)
    for i in {1..30}; do
        if mountpoint -q "$MOUNT_DIR"; then
            systemd-notify --ready
            break
        fi
        sleep 1
    done
    # Если не дождались — ошибка
    if ! mountpoint -q "$MOUNT_DIR"; then
        echo "Error: mount point $MOUNT_DIR not ready after 30s"
        kill $WEED_PID 2>/dev/null
        exit 1
    fi
else
    # Для остальных типов — 3 секунды
    sleep 3
    systemd-notify --ready
fi

# Передаём сигналы в weed для graceful shutdown
trap 'kill $WEED_PID 2>/dev/null; wait $WEED_PID' SIGTERM SIGINT

# Ждём завершения weed (блокируемся)
wait $WEED_PID
```

**Ключевые моменты:**
- `weed` запускается в фоне через `&`
- Для mount: цикл проверки `mountpoint -q` с таймаутом 30 сек
- Для остальных: фиксированная задержка 3 сек
- После готовности — `systemd-notify --ready`
- `trap` передаёт SIGTERM/SIGINT в weed для корректного unmount
- `wait $WEED_PID` — скрипт остаётся активным пока weed работает

## Обработка ошибок

**Weed падает до отправки notify:**
- Проверка `kill -0 $WEED_PID` после запуска
- Выход с ошибкой, systemd не запустит зависимые сервисы

**Mount point не появляется (таймаут 30 сек):**
- Убиваем процесс weed
- Выходим с ошибкой
- Systemd увидит неудачный старт, зависимые сервисы не запустятся

**Weed падает после notify:**
- `wait $WEED_PID` вернёт exit code процесса
- Скрипт завершится с тем же кодом
- Systemd перезапустит сервис (Restart=always)

**Graceful shutdown (SIGTERM):**
- При остановке сервиса systemd шлёт SIGTERM скрипту
- trap передаёт его в weed для корректного unmount

## Файлы для изменения

| Файл | Изменение |
|------|-----------|
| `dist/seaweedfs@.service` | Type=notify, NotifyAccess=all, TimeoutStartSec=60 |
| `dist/seaweedfs-service.sh` | Фоновый запуск, notify логика, trap для сигналов |

## Тестирование

```bash
# 1. Проверка notify работает
systemctl stop seaweedfs@zinin-mount nginx
systemctl start seaweedfs@zinin-mount
systemctl status seaweedfs@zinin-mount  # должен быть active

# 2. Проверка зависимостей
systemctl stop seaweedfs@zinin-mount nginx
systemctl start nginx  # должен потянуть mount и дождаться его
systemctl status nginx seaweedfs@zinin-mount  # оба active
```
