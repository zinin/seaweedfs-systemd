---
name: seaweedfs-update-schema
description: Update XSD schema from SeaweedFS help documentation - adds new parameters, removes deprecated ones, creates new Args types for new commands
---

# SeaweedFS Update Schema

## Overview

Автоматически обновляет XSD-схему `xsd/seaweedfs-systemd.xsd` на основе актуальной документации из `help.txt`.

## When to Use

- После обновления SeaweedFS и регенерации help.txt
- Для синхронизации схемы с новой версией SeaweedFS
- После выполнения `/seaweedfs-update-help`

## Quick Reference

| File | Purpose |
|------|---------|
| `help.txt` | Источник актуальных параметров |
| `xsd/seaweedfs-systemd.xsd` | Целевая схема для обновления |

## Algorithm

### Step 1: Parse help.txt

1. Читай файл `help.txt` в корне проекта

2. Найди все блоки команд по паттерну:
   ```
   ============================================================
   Command: weed help <command_name>
   ============================================================
   ```

3. Для каждого блока:
   - Извлеки имя команды из `weed help <command_name>`
   - Найди секцию `Default Parameters:`
   - Парси параметры до следующего разделителя `====`

4. Формат параметра в help.txt:
   ```
     -paramName type
       	description text (default value)
   ```

   Примеры:
   ```
     -port int
       	server http listen port (default 9333)
     -debug
       	enable debug mode
     -garbageThreshold float
       	threshold to vacuum (default 0.3)
     -timeAgo duration
       	start time before now
   ```

5. Извлеки для каждого параметра:
   - Имя (без дефиса): `port`, `debug`, `garbageThreshold`
   - Go-тип (если есть): `int`, `string`, `float`, `duration`, `uint`
   - Default value (если есть): из `(default ...)` в описании