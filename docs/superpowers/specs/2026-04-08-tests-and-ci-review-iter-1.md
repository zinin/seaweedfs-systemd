# Review Iteration 1 — 2026-04-08 19:35

## Источник

- Design: `docs/superpowers/specs/2026-04-08-tests-and-ci-design.md`
- Plan: `docs/superpowers/plans/2026-04-08-tests-and-ci.md`
- Review agents: codex-executor, ccs-executor (glm, albb-glm, albb-qwen, albb-kimi, albb-minimax)
- Merged output: `docs/superpowers/specs/2026-04-08-tests-and-ci-review-merged-iter-1.md`
- Gemini: FAILED (hung after reading files)

## Замечания

### [CRITICAL-1] set -u + empty ARGS[@] crashes bash < 4.4

> `"${ARGS[@]}"` with empty array triggers "unbound variable" under set -u.

**Источник:** GLM, albb-glm, albb-qwen
**Статус:** Автоисправлено
**Ответ:** Add guard `[[ ${#ARGS[@]} -gt 0 ]] && CMD+=("${ARGS[@]}")`
**Действие:** Updated design spec §1.4 and plan Task 2

---

### [CRITICAL-2] iam fixture uses nonexistent `<masters>` element

> IamArgs XSD only defines `master`, not `masters`.

**Источник:** GLM, albb-glm
**Статус:** Автоисправлено
**Ответ:** Changed `<masters>` to `<master>` in fixture
**Действие:** Updated plan Task 3 Step 2

---

### [CRITICAL-3] Integration tests: export -f + command -v incompatibility

> `command -v xmllint` doesn't find bash functions. Must use PATH-based stub scripts.

**Источник:** GLM, albb-glm, albb-qwen
**Статус:** Автоисправлено
**Ответ:** Added `setup_stub_path()` to helpers/setup.bash, rewrote all integration tests
**Действие:** Updated design spec §3.2, plan Task 4 and Task 5/6

---

### [CRITICAL-4] Path traversal in deps.sh via unit names

> Unit names from XML flow into file paths without sanitization.

**Источник:** Codex
**Статус:** Обсуждено с пользователем
**Ответ:** Добавить валидацию unit names regex `^[a-zA-Z0-9@._:-]+$`
**Действие:** Added design spec §2.1, plan Task 1 updated

---

### [MAJOR-5] RUN_USER/RUN_GROUP not sanitized + partial config

> Values flow into sudo without validation. Partial config causes silent root execution.

**Источник:** albb-kimi, albb-minimax, Codex
**Статус:** Обсуждено с пользователем
**Ответ:** Валидация regex + error (не warning) при частичном задании
**Действие:** Updated design spec §1.6, plan Task 2

---

### [MAJOR-7] deps.sh: only .service and .target suffixes handled

> .socket, .mount, .timer, .path broken by auto-append of .service.

**Источник:** Codex
**Статус:** Обсуждено с пользователем
**Ответ:** Поддержать все systemd suffixes. Дописывать .service только если suffix отсутствует.
**Действие:** Added design spec §2.2

---

### [MAJOR-8] wait_for_ready: no PID recheck before notify

> May send false READY after process death.

**Источник:** Codex
**Статус:** Обсуждено с пользователем
**Ответ:** Добавить kill -0 проверку перед каждым notify и в цикле mountpoint
**Действие:** Added design spec §1.7, updated plan Task 2 wait_for_ready

---

### [MAJOR-12] SERVICE_TYPE not validated if xmllint stubbed

> XPath injection via args_path possible when xmllint bypassed.

**Источник:** GLM
**Статус:** Автоисправлено
**Ответ:** Added regex validation for SERVICE_TYPE
**Действие:** Updated design spec §1.3, plan Task 2

---

### [MINOR-14/20] BATS version not pinned in CI

> `git clone --depth 1` without tag — no reproducibility.

**Источник:** GLM
**Статус:** Автоисправлено
**Ответ:** Pinned to `--branch v1.11.1`
**Действие:** Updated design spec §5, plan Task 9

---

### [MINOR-9/10/15/16] Missing tests for shell metacharacters, spaces, sudo, SIGTERM

**Источник:** GLM, albb-kimi, Codex
**Статус:** Отклонено (не блокируют)
**Ответ:** Отмечено для добавления при реализации. Не включаем в дизайн/план чтобы не раздувать скоуп — основные пути покрыты.

---

### [MINOR-17] detect_cycles multiple messages for same cycle

**Источник:** GLM, albb-qwen
**Статус:** Отклонено
**Ответ:** Существующее поведение, не в скоупе этого PR.

---

### [MINOR-18/19] Makefile filter-out, SC2155

**Статус:** Отклонено
**Ответ:** Filter-out работает корректно (проверено). SC2155 ловится shellcheck.

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| design spec | §1.3: добавлена валидация SERVICE_TYPE |
| design spec | §1.4: guard для пустого ARGS[@] |
| design spec | §1.6: переписано на validate+error вместо warning, добавлена validate_unix_name |
| design spec | §1.7: новая секция — fix wait_for_ready PID recheck |
| design spec | §2.1: новая секция — validate unit names |
| design spec | §2.2: новая секция — support all systemd suffixes |
| design spec | §3.2: PATH-based stubs вместо export -f |
| design spec | §5: pinned BATS version |
| design spec | summary table updated |
| plan Task 2 | validate_unix_name, SERVICE_TYPE validation, ARGS guard, wait_for_ready PID recheck |
| plan Task 3 | `<masters>` → `<master>` в iam fixture |
| plan Task 4 | setup_stub_path() с PATH-based стубами |
| plan Task 5 | все интеграционные тесты переписаны на setup_stub_path |
| plan Task 6 | все интеграционные тесты переписаны на setup_stub_path |
| plan Task 9 | pinned BATS v1.11.1 |

## Статистика

- Всего замечаний: 22
- Автоисправлено: 5
- Обсуждено с пользователем: 4
- Отклонено: 6
- Информационные (не требуют действий): 7
- Пользователь сказал "стоп": Нет
- Агенты: codex-executor, ccs-executor (glm, albb-glm, albb-qwen, albb-kimi, albb-minimax)
- Gemini: FAILED
