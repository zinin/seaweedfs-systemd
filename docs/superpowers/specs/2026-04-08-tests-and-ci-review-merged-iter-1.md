# Merged Design Review — Iteration 1

## Agents

- codex-executor (gpt-5.4) — 2 Critical, 6 Major
- gemini-executor — FAILED (hung after reading files)
- ccs-executor (glm / glm-5.1) — 3 Critical, 4 Major, 5 Minor, 4 Suggestion
- ccs-executor (albb-glm / glm-5) — 3 Critical, 3 Major, 9 Minor
- ccs-executor (albb-qwen / qwen3-coder-plus) — 2 Critical, 3 Major, 3 Minor, 1 Suggestion
- ccs-executor (albb-kimi / kimi-k2.5) — 2 Critical, 3 Major, 4 Minor, 1 Suggestion
- ccs-executor (albb-minimax / MiniMax-M2.5) — 4 Critical, 3 Major, 2 Minor, 2 Suggestion

## Deduplicated Issues

### CRITICAL

1. **set -u + empty ARGS[@] crashes bash < 4.4** — `"${ARGS[@]}"` with empty array triggers "unbound variable" under set -u. Sources: GLM, albb-glm, albb-qwen.
2. **iam fixture uses nonexistent `<masters>` element** — IamArgs XSD only defines `master`, not `masters`. Sources: GLM, albb-glm.
3. **Integration tests: `export -f` + `command -v` incompatibility** — `command -v xmllint` doesn't find bash functions. Tests will fail. Must use PATH-based stub scripts. Sources: GLM, albb-glm, albb-qwen.
4. **Path traversal in deps.sh** — unit names from XML flow into file paths without sanitization. `../` could write outside target directory. Source: Codex.

### MAJOR

5. **RUN_USER/RUN_GROUP not sanitized** — XML values flow into `sudo -u/-g` without validation. Sources: albb-kimi, albb-minimax.
6. **Partial RUN_USER/RUN_GROUP: warning vs error** — Service may run as root silently. Sources: albb-kimi, albb-minimax, Codex.
7. **deps.sh: only .service and .target suffixes handled** — .socket, .mount, .timer, .path broken. Source: Codex.
8. **wait_for_ready: no PID recheck before notify** — May send false READY after process death. Source: Codex.
9. **No tests for XML values with shell metacharacters** — `$(rm -rf /)` in XML values not tested. Sources: albb-kimi, GLM.
10. **No tests for sudo/RUN_DIR paths** — Critical production codepaths uncovered. Sources: GLM, Codex.
11. **XSD should enforce ID format** — xs:string too permissive; XSD and shell validators should agree. Source: Codex.
12. **SERVICE_TYPE not validated if xmllint stubbed** — XPath injection via args_path possible. Source: GLM.
13. **sudo may not inherit cwd in subshell pattern** — `(cd DIR && exec sudo ...)` vs `sudo ... bash -c "cd DIR && ..."`. Sources: albb-qwen, GLM.

### MINOR

14. **BATS version not pinned in CI** — `git clone --depth 1` without tag. Source: GLM.
15. **No test for signal handling (SIGTERM)** — Critical for systemd services. Source: GLM.
16. **No test for values with spaces** — Spec mentions it, plan omits it. Source: GLM.
17. **detect_cycles may output multiple messages for same cycle** — DFS continues after finding cycle. Sources: GLM, albb-qwen.
18. **Makefile filter-out pattern edge cases** — `%invalid-%.xml` may not match all naming variations. Source: albb-kimi.
19. **shellcheck SC2155 expected** — `local var=$(...)` masks exit codes. Source: albb-glm.

### SUGGESTION

20. **Pin BATS version in CI** — Use `--branch v1.11.0`. Source: GLM.
21. **Add `--quiet` to xmllint in Makefile** — Reduce noise. Source: albb-minimax.
22. **No CI caching** — Acceptable for small project. Source: GLM.
