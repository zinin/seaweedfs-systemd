# Project Structure Refactor

## Problem

Triple file duplication:
- `seaweedfs-service.sh` — root and ansible/files/
- `seaweedfs@.service` — root (outdated) and ansible/files/ (current)
- `seaweedfs-systemd.xsd` — xsd/ and ansible/files/

## Solution

Create `dist/` folder for deployment artifacts. Remove `ansible/files/`.

## Structure: Before → After

**Before:**
```
/
├── ansible/
│   ├── files/
│   │   ├── seaweedfs-service.sh      # duplicate
│   │   ├── seaweedfs@.service        # current version
│   │   └── seaweedfs-systemd.xsd     # duplicate
│   ├── tasks/main.yml
│   └── vars/main.yml
├── xsd/
│   └── seaweedfs-systemd.xsd
├── seaweedfs-service.sh
├── seaweedfs@.service                # outdated
└── ...
```

**After:**
```
/
├── ansible/
│   ├── tasks/main.yml                # updated paths
│   └── vars/main.yml
├── dist/
│   ├── seaweedfs-service.sh
│   └── seaweedfs@.service
├── xsd/
│   └── seaweedfs-systemd.xsd
└── ...
```

## Changes

1. Create `dist/` folder
2. Copy `ansible/files/seaweedfs@.service` → `dist/` (current version)
3. Move `seaweedfs-service.sh` → `dist/`
4. Delete outdated `seaweedfs@.service` from root
5. Delete `ansible/files/` entirely
6. Update paths in `ansible/tasks/main.yml`
7. Update `CLAUDE.md` architecture table
