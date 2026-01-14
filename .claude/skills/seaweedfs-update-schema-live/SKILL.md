---
name: seaweedfs-update-schema-live
description: Update XSD schema by calling ./weed directly, processing each command in isolated subagent
---

# SeaweedFS Update Schema Live

## Overview

Updates XSD schema directly by calling `./weed` binary. Each command is processed in a separate subagent with clean context, reducing errors when handling large number of parameters.

## When to Use

- After downloading new `./weed` via `/seaweedfs-update-help`
- As alternative to `/seaweedfs-update-schema` for more reliable processing
- When updating schema for many commands at once

## Prerequisites

- Executable `./weed` in project root (run `/seaweedfs-update-help` first)
- XSD schema at `xsd/seaweedfs-systemd.xsd`

## Quick Reference

| File | Purpose |
|------|---------|
| `./weed` | SeaweedFS binary |
| `xsd/seaweedfs-systemd.xsd` | Target schema to update |
