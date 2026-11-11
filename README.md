# SeaweedFS Systemd Integration

This project provides a systemd integration for managing SeaweedFS services using XML configuration files. It includes an XSD schema for validating the configuration, a Bash script for launching services, and Ansible playbook for deployment.

## Table of Contents
- [Overview](#overview)
- [Features](#features)
- [Usage](#usage)
- [Configuration](#configuration)
- [Ansible Deployment](#ansible-deployment)
- [Contributing](#contributing)
- [License](#license)

## Overview
SeaweedFS is a distributed file system designed to store and serve billions of files quickly. This project enhances SeaweedFS by providing a systemd-based service management solution, allowing you to define and manage SeaweedFS services using XML configuration files.

## Features

- **XML Configuration**: Define SeaweedFS services using XML files.
- **XSD Validation**: Validate XML configuration files against an XSD schema.
- **Systemd Integration**: Manage SeaweedFS services using systemd.
- **Ansible Deployment**: Automate the deployment of SeaweedFS services using Ansible.
- **Dependencies Management**: Manage systemd service dependencies.
- **Automatic Updates**: XSD schema and version are kept in sync with SeaweedFS releases via a daily [Claude Code](https://claude.ai/code) scheduled task.

## Usage

---

### XML Configuration

Define your SeaweedFS services in an XML file (e.g., `/etc/seaweedfs/services.xml`). The XML file should conform to the `seaweedfs-systemd.xsd` schema.

Example XML configuration:

```xml
<services xmlns="http://zinin.ru/xml/ns/seaweedfs-systemd" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://zinin.ru/xml/ns/seaweedfs-systemd http://zinin.ru/xml/ns/seaweedfs-systemd/seaweedfs-systemd-1.0.xsd">
<service>
    <id>server1-server</id>
    <type>server</type>
    <run-user>seaweedfs</run-user>
    <run-group>seaweedfs</run-group>
    <run-dir>/var/lib/seaweedfs/server1</run-dir>
    <config-dir>/var/lib/seaweedfs/server1</config-dir>
    <logs-dir>/var/lib/seaweedfs/server1/logs</logs-dir>
    <server-args>
        <dir>/mnt/raiddata/seaweedfs/server1/data</dir>
        <ip>server.hostname.com</ip>
        <ip.bind>0.0.0.0</ip.bind>
        <filer>true</filer>
        <metricsPort>10300</metricsPort>
        <filer.localSocket>/var/lib/seaweedfs/seaweedfs-filer-server1.sock</filer.localSocket>
        <filer.port>10200</filer.port>
        <master.port>10000</master.port>
        <master.volumeSizeLimitMB>1000</master.volumeSizeLimitMB>
        <volume.dir.idx>/mnt/raiddata/seaweedfs/server1/idx</volume.dir.idx>
        <volume.max>10000</volume.max>
        <volume.port>10100</volume.port>
    </server-args>
</service>

<service>
    <id>server2-server</id>
    <type>server</type>
    <run-user>seaweedfs</run-user>
    <run-group>seaweedfs</run-group>
    <run-dir>/var/lib/seaweedfs/server2</run-dir>
    <config-dir>var/lib/seaweedfs/server2</config-dir>
    <logs-dir>/var/lib/seaweedfs/server2/logs</logs-dir>
    <server-args>
        <dir>/mnt/raiddata/seaweedfs/server2/data</dir>
        <ip>server.hostname.com</ip>
        <ip.bind>0.0.0.0</ip.bind>
        <filer>true</filer>
        <metricsPort>10301</metricsPort>
        <filer.localSocket>/var/lib/seaweedfs/seaweedfs-filer-server2.sock</filer.localSocket>
        <filer.port>10201</filer.port>
        <master.port>10001</master.port>
        <master.volumeSizeLimitMB>1000</master.volumeSizeLimitMB>
        <volume.dir.idx>/mnt/raiddata/seaweedfs/server2/idx</volume.dir.idx>
        <volume.max>10000</volume.max>
        <volume.port>10101</volume.port>
    </server-args>
</service>

<!-- Mount depends on server (won't start until server is running) -->
<service>
    <id>server1-mount</id>
    <type>mount</type>
    <run-user>root</run-user>
    <run-group>root</run-group>
    <run-dir>/var/lib/seaweedfs/server1</run-dir>
    <config-dir>/var/lib/seaweedfs/server1</config-dir>
    <logs-dir>/var/lib/seaweedfs/server1/logs</logs-dir>
    <!-- This mount requires server1-server to be running first -->
    <dependencies>
        <service>server1-server</service>
    </dependencies>
    <!-- External service myapp will be bound to this mount (stops if mount stops) -->
    <dependents>
        <unit dependency-type="binds-to">myapp</unit>
    </dependents>
    <mount-args>
        <filer>localhost:10200</filer>
        <dir>/mnt/seaweedfs/server1</dir>
    </mount-args>
</service>

<service>
    <id>server2-mount</id>
    <type>mount</type>
    <run-user>root</run-user>
    <run-group>root</run-group>
    <run-dir>/var/lib/seaweedfs/server2</run-dir>
    <config-dir>var/lib/seawedfs/server2</config-dir>
    <logs-dir>/var/lib/seaweedfs/server2/logs</logs-dir>
    <!-- Soft dependency: will try to start server2-server but won't fail if unavailable -->
    <dependencies>
        <service dependency-type="wants">server2-server</service>
    </dependencies>
    <mount-args>
        <filer>localhost:10201</filer>
        <dir>/mnt/seaweedfs/server2</dir>
    </mount-args>
</service>
</services>
```

### Launching Services

Use the `seaweedfs-service.sh` script to launch a SeaweedFS service:

```sh
./seaweedfs-service.sh master1 /etc/seaweedfs/services.xml
```

### Systemd Service

You can also manage services using systemd:

```sh
sudo systemctl start seaweedfs@master1
sudo systemctl enable seaweedfs@master1
```

Units are `Type=notify`. A service is reported ready when:

- `mount` — the mount point is mounted (up to 30 s, otherwise the start fails);
- `server` — its master, volume server and filer listen on their HTTP and gRPC ports (gRPC is port + 10000 unless `*.port.grpc` is set), and then its master has a raft leader and knows all volumes of its volume server. The filer counts when `<filer>true</filer>` is set or when `s3`, `sftp`, `iam`, `webdav`, `mq.broker` or `mq.agent` turn it on, as `weed server` does. Until the master knows the volumes, a read fails with `volume N not found`, and `weed mount` keeps that answer for about 30 s; so the units ordered after the server, such as `mount` and `filer.sync`, start only when reads work. The master is asked over HTTP with `curl` (`/cluster/status`, `/dir/status`, the volume server's `/status`) and the JSON is read with `python3`; without either tool only the ports are waited for. Both waits together are capped by `SEAWEEDFS_READY_TIMEOUT` (whole seconds of wall-clock time, default 45); after that the server is reported ready anyway, with a warning in the journal. If weed exits during the wait, the start fails and `Restart=` starts the server again; `seaweedfs-deps.sh` gives server units `RestartMode=direct`, so the units ordered after the server wait for it instead of failing (see [Dependencies Management](#dependencies-management));
- any other type — the process is still alive 3 seconds after start.

### Dependencies Management

The `seaweedfs-deps.sh` script manages systemd drop-in files for service dependencies.

#### Commands

```sh
# Create drop-in files from XML config
./seaweedfs-deps.sh apply /etc/seaweedfs/services.xml

# Show what would be done (dry-run)
./seaweedfs-deps.sh check /etc/seaweedfs/services.xml

# Remove all seaweedfs drop-in files
./seaweedfs-deps.sh clean
```

#### XML Configuration

Use `<dependencies>` to specify what a service needs:
- `<service>` — reference to another SeaweedFS service by id
- `<unit>` — external systemd unit

Use `<dependents>` to specify external units that depend on this service:
- `<unit>` — external systemd unit name

The `dependency-type` attribute controls systemd dependency directive:
- `requires` (default) — hard dependency
- `binds-to` — tight coupling (stops when dependency stops)
- `wants` — soft dependency

See the [XML Configuration](#xml-configuration) example above for usage.

#### Servers restart in place

Every `server` service also gets a drop-in, with or without `<dependencies>`:

```ini
[Service]
RestartMode=direct
```

A server is reported ready only once its ports listen and its master knows its volumes. With the default restart mode, a server that fails during that wait fails its start job, and systemd then fails the start of every unit ordered after it — `mount`, `filer.sync`, units bound to the mount — with result `dependency`; `Restart=` brings back only the server. With `RestartMode=direct` the server goes straight back to activating, and those units wait for it. The same applies to a running server that crashes: it restarts alone, and the units that need it are not stopped or restarted with it. A manual `systemctl restart` of the server still restarts them. Mounts keep the default mode: units bound to a mount must stop when it fails.

`RestartMode=` needs systemd 254 or newer; older versions ignore the line with a warning. After updating `seaweedfs-service.sh`, run `seaweedfs-deps.sh apply` so that servers get the drop-in.

---

## Configuration

### XSD Schema

The `seaweedfs-systemd.xsd` schema defines the structure of the XML configuration file. It includes elements for defining services, their types, and their arguments.

### Bash Script

The `seaweedfs-service.sh` script parses the XML configuration and launches the appropriate SeaweedFS service. It supports all SeaweedFS service types and their respective arguments.

### Ansible Playbook

The Ansible playbook automates the deployment of SeaweedFS services. It installs dependencies, downloads the SeaweedFS binary, and sets up systemd services.

---

## Ansible Deployment

The Ansible playbook is located in the `ansible` directory. It includes tasks for:

- Creating users and groups
- Downloading and extracting SeaweedFS
- Setting up systemd services
- Installing dependencies

Do deploy using Ansible:

```sh
ansible-playbook -I inventory ansible/tasks/main.yml
```

---

## Automatic Updates

The XSD schema and SeaweedFS version are automatically kept up to date. A Claude Code scheduled task runs daily and:

1. Checks the latest [SeaweedFS release](https://github.com/seaweedfs/seaweedfs/releases) on GitHub
2. If a new version is available — downloads it, updates the XSD schema and Ansible vars
3. Creates a pull request with the changes for review

This ensures the configuration schema always matches the latest SeaweedFS parameters.

## Development

### Prerequisites

```sh
sudo apt-get install xmlstarlet libxml2-utils shellcheck
git clone --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core.git /tmp/bats
sudo /tmp/bats/install.sh /usr/local
```

### Running tests

```sh
make all              # lint + validate + test (everything)
make lint             # shellcheck for bash scripts
make validate         # xmllint XSD validation of fixtures
make test             # all BATS tests
make test-unit        # only unit tests (fast, no xmlstarlet needed)
make test-integration # only integration tests
```

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

This project is licensed under the Apache License Version 2.0. See the [LICENSE-2.0.txt](https://www.apache.org/licenses/LICENSE-2.0.txt) file for details.
