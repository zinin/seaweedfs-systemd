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
