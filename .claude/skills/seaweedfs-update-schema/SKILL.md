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

### Step 2: Type Mapping

**Go type → XSD type:**

| Go type | XSD type | Пример |
|---------|----------|--------|
| `int` | `xs:int` | `-port int` |
| `int64` | `xs:long` | `-size int64` |
| `uint` | `xs:unsignedInt` | `-volumeSizeLimitMB uint` |
| `float` | `xs:float` | `-garbageThreshold float` |
| `float64` | `xs:double` | `-ratio float64` |
| `string` | `xs:string` | `-dir string` |
| `duration` | `xs:duration` | `-timeAgo duration` |
| `value` | `xs:string` | `-config value` |
| (no type) | `xs:boolean` | `-debug` |

**Эвристика при отсутствии типа:**
- `(default true)` или `(default false)` → `xs:boolean`
- `(default 123)` (число) → `xs:int`
- `(default 0.5)` (дробное) → `xs:float`
- `(default "text")` или любой текст → `xs:string`
- Неясно → спроси пользователя

### Step 3: Command Name → Args Type

**Правило преобразования:**
1. Убрать `weed help ` из имени команды
2. Разделить по `.`
3. Каждую часть с заглавной буквы
4. Добавить `Args`

**Примеры:**
| Команда | Args Type |
|---------|-----------|
| `weed help server` | `ServerArgs` |
| `weed help master` | `MasterArgs` |
| `weed help filer` | `FilerArgs` |
| `weed help filer.backup` | `FilerBackupArgs` |
| `weed help filer.meta.backup` | `FilerMetaBackupArgs` |
| `weed help mq.broker` | `MqBrokerArgs` |
| `weed help s3` | `S3Args` |

**Обратное преобразование (Args Type → команда):**
- `ServerArgs` → `server`
- `FilerBackupArgs` → `filer.backup`
- `MqBrokerArgs` → `mq.broker`