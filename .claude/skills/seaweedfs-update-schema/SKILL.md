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

### Step 4: Compare with Current XSD

1. Читай файл `xsd/seaweedfs-systemd.xsd`

2. Для каждого `xs:complexType name="*Args"`:
   - Извлеки имя типа (например, `ServerArgs`)
   - Найди все `xs:element` внутри `xs:sequence`
   - Для каждого элемента извлеки: `name`, `type`, `minOccurs`

3. Сопоставь с данными из help.txt:
   - Преобразуй имя типа в команду: `ServerArgs` → `server`
   - Найди соответствующую команду в parsed данных

4. Категоризируй изменения:

   **Новые параметры** (есть в help.txt, нет в XSD):
   - Добавить в схему

   **Удалённые параметры** (есть в XSD, нет в help.txt):
   - Проверить на переименование (см. Step 5)
   - Если не переименование → спросить подтверждение на удаление

   **Изменённый тип** (параметр есть в обоих, тип отличается):
   - Обновить тип автоматически

   **Новые команды** (есть в help.txt, нет Args типа в XSD):
   - Создать новый тип Args

### Step 5: Detect Renames (Levenshtein)

Для каждого "удалённого" параметра:

1. Вычисли схожесть с каждым "новым" параметром
2. Используй Levenshtein distance или схожесть строк
3. Если схожесть ≥ 70%:
   ```
   Параметр 'server' удалён.
   Похож на новый параметр 'master' (схожесть 75%).
   Это переименование? (да/нет/удалить оба/оставить оба)
   ```

4. Если схожесть < 70%:
   ```
   Параметр 'oldParam' отсутствует в новой версии.
   Удалить из схемы? (да/нет)
   ```

### Step 6: Apply Changes to XSD

**Добавление нового параметра:**

Вставь в `xs:sequence` соответствующего типа Args в алфавитном порядке:

```xml
<xs:element name="newParam" type="xs:int" minOccurs="0"/>
```

- По умолчанию `minOccurs="0"` (опциональный)
- Если параметр явно обязательный (нет default, критичный) → без `minOccurs`

**Удаление параметра:**

Удали строку `<xs:element name="paramName" .../>` из `xs:sequence`

**Изменение типа:**

Замени значение атрибута `type`:
```xml
<!-- Было: -->
<xs:element name="param" type="xs:string" minOccurs="0"/>
<!-- Стало: -->
<xs:element name="param" type="xs:int" minOccurs="0"/>
```

**Создание нового типа Args:**

1. Добавь в `ServiceTypeEnum` новое значение:
```xml
<xs:enumeration value="new.command"/>
```

2. Добавь в `xs:choice` внутри `ServiceType`:
```xml
<xs:element name="new-command-args" type="tns:NewCommandArgs"/>
```

3. Создай новый `xs:complexType`:
```xml
<xs:complexType name="NewCommandArgs">
    <xs:sequence>
        <xs:element name="param1" type="xs:string" minOccurs="0"/>
        <xs:element name="param2" type="xs:int" minOccurs="0"/>
    </xs:sequence>
</xs:complexType>
```

**Форматирование:**
- Отступы: 4 пробела
- Порядок элементов внутри sequence: алфавитный
- Порядок типов Args: сохранять существующий, новые в конец

## Edge Cases

### Вложенные параметры (с точками в имени)

Параметры типа `s3.port`, `master.volumeSizeLimitMB`:
- Это НЕ разделитель команд
- В XSD сохраняй как есть: `<xs:element name="s3.port" .../>`
- Точка в имени команды (`filer.backup`) — это разделитель команд
- Точка в имени параметра (`s3.port`) — часть имени параметра

### Deprecated параметры

Если описание содержит "deprecated":
```
-masters string
    comma-separated master servers (deprecated, use -master instead)
```

Действие:
```
Параметр 'masters' помечен как deprecated.
Рекомендация: удалить из схемы, использовать 'master'.
Удалить? (да/нет)
```

### Команды без параметров

Некоторые команды (например, `weed autocomplete`) имеют пустую секцию `Default Parameters:`.

Действие при первом таком случае:
```
Команда 'autocomplete' не имеет параметров.
Создать пустой тип AutocompleteArgs? (да/пропустить)
```

### Определение обязательности

Параметр обязателен если:
- Нет `(default ...)` в описании
- В описании есть слова "required", "must", "необходим"
- Команда не работает без этого параметра (по контексту)

Иначе — опционален (`minOccurs="0"`)

При сомнении — спроси пользователя.

### Ошибки

**help.txt не найден:**
```
Ошибка: файл help.txt не найден в корне проекта.
Сначала выполни /seaweedfs-update-help для генерации документации.
```

**XSD невалиден:**
```
Ошибка: не удалось распарсить xsd/seaweedfs-systemd.xsd.
Проверь синтаксис XML вручную.
```

## Usage

```
/seaweedfs-update-schema
```

## Output

После выполнения выведи отчёт:

```
=== SeaweedFS Schema Update Report ===

Проанализировано команд: 25
Типов Args в схеме: 14

ДОБАВЛЕНО параметров: 12
  ServerArgs:
    + adminPassword (xs:string)
    + adminUser (xs:string)
  FilerArgs:
    + sftp (xs:boolean)
    + sftp.port (xs:int)
  ...

УДАЛЕНО параметров: 3
  ServerArgs:
    - oldParam (подтверждено пользователем)
  ...

ИЗМЕНЕНО типов: 2
  MasterArgs.volumeSizeLimitMB: xs:int → xs:unsignedInt

НОВЫЕ типы Args: 2
  + AdminArgs (15 параметров)
  + MiniArgs (47 параметров)

Схема обновлена: xsd/seaweedfs-systemd.xsd
```

## Workflow Integration

Типичный порядок использования:

1. `/seaweedfs-update-help` — скачать новую версию, сгенерировать help.txt
2. `/seaweedfs-update-schema` — обновить XSD на основе help.txt
3. Проверить изменения: `git diff xsd/seaweedfs-systemd.xsd`
4. Commit изменений