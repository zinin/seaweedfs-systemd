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

- [XML Configuration](https://example.com): Define SeaweedFS services using XML files.
- [XSD Validation](https://example.com): Validate XML configuration files against an XSD schema.
- [Systemd Integration](https://example.com): Manage SeaweedFS services using systemd.
- [Ansible Deployment](https://example.com): Automate the deployment of SeaweedFS services using Ansible.

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

<service>
    <id>server1-mount</id>
    <type>mount</type>
    <run-user>root</run-user>
    <run-group>root</run-group>
    <run-dir>/var/lib/seaweedfs/server1</run-dir>
    <config-dir>/var/lib/seaweedfs/server1</config-dir>
    <logs-dir>/var/lib/seaweedfs/server1/logs</logs-dir>
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

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

This project is licensed under the Apache License Version 2.0. See the [LICENSE-2.0.txt](https://www.apache.org/licenses/LICENSE-2.0.txt) file for details.
