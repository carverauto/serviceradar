# ServiceRadar Build System Documentation

## Overview

The ServiceRadar build system has been consolidated into a single script, `setup-package.sh`, which replaces the multiple `setup-deb-*.sh` scripts. This script builds both Debian (`.deb`) and RPM (`.rpm`) packages for all components of the ServiceRadar project, using a configuration-driven approach defined in `packaging/components.json`. The system supports components written in Go, Rust, and Node.js, as well as external binaries (e.g., NATS), and organizes Dockerfiles in `docker/deb/` and `docker/rpm/` directories (with some exceptions in `cmd/checkers/`).

This documentation explains the structure of `components.json`, how to use `setup-package.sh`, and how to add new components. It also addresses the management of packaging files and the rationale for dynamic generation of Debian control files.

## Components.json Structure

The `components.json` file, located at `packaging/components.json`, defines the configuration for each ServiceRadar component. Below is a detailed description of all fields, their purposes, and whether they are required or optional.

### Top-Level Fields

Each entry in `components.json` is a JSON object representing a component. The array contains entries for components like core, web, agent, etc.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| name | String | Yes | Unique identifier for the component (e.g., `core`, `rperf-client`). Used to select components in `setup-package.sh`. |
| package_name | String | Yes | Name of the package (e.g., `serviceradar-core`, `serviceradar-rperf-checker`). Used in package filenames and metadata. |
| version | String | Yes | Version of the component (e.g., `1.0.32`). Can be overridden by the `VERSION` environment variable. |
| description | String | Yes | Description of the package, used in the Debian `control` file and RPM spec file. |
| maintainer | String | Yes | Maintainer contact information (e.g., `Michael Freeman <mfreeman@carverauto.dev>`). |
| architecture | String | Yes | Architecture for the package (e.g., `amd64`). |
| section | String | Yes | Package section (e.g., `utils`, `net`). Used in Debian `control` file. |
| priority | String | Yes | Package priority (e.g., `optional`). Used in Debian `control` file. |
| deb | Object | Yes | Debian-specific configuration (see below). |
| rpm | Object | Yes | RPM-specific configuration (see below). |
| binary | Object | No | Configuration for building the component's binary (see below). Required if the component has a binary. |
| build_method | String | No | Build method for non-binary components (e.g., `npm` for `web`, `external` for `nats`). Options: `go`, `rust`, `npm`, `docker`, `external`. |
| build_dir | String | No | Directory for building non-binary components (e.g., `web` for Next.js). Used with `npm` build method. |
| output_dir | String | No | Destination directory for non-binary build outputs (e.g., `/usr/local/share/serviceradar-web`). Used with `npm` build method. |
| custom_steps | Array | No | Custom commands to run before building (e.g., protobuf compilation for `rperf-client`). |
| config_files | Array | No | List of configuration files to include in the package (see below). |
| systemd_service | Object | No | Systemd service file configuration (see below). |
| postinst | Object | No | Post-install script configuration (see below). |
| prerm | Object | No | Pre-removal script configuration (see below). |
| conffiles | Array | No | List of configuration files to mark as preserved during upgrades (e.g., `/etc/serviceradar/core.json`). |
| additional_dirs | Array | No | Additional directories to create in the package (e.g., `/var/log/rperf`). |

### deb and rpm Objects

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| depends | Array | Yes | List of package dependencies (e.g., `["systemd", "nodejs (>= 16.0.0)"]` for Debian, `["systemd", "nodejs"]` for RPM). |
| dockerfile | String | No | Path to the Dockerfile for building the package (e.g., `docker/deb/Dockerfile.core` for Debian, `docker/rpm/Dockerfile.rpm.core` for RPM). Null if not using Docker. |
| release | String | No | RPM release number (e.g., `1`). Only used for RPM builds. Defaults to `1`. |

### binary Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| source_path | String | No | Source directory for the binary (e.g., `cmd/core`). Required for `go` and `docker` build methods. |
| build_method | String | Yes | Build method for the binary (`go`, `rust`, `docker`). |
| dockerfile | String | No | Path to the Dockerfile for building the binary (e.g., `cmd/checkers/rperf-client/Dockerfile`). Required for `rust` and some `docker` builds. |
| output_path | String | Yes | Destination path for the binary in the package (e.g., `/usr/local/bin/serviceradar-core`). |

### external_binary Object (Used with build_method: external)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| source_url | String | Yes | URL to download the external binary (e.g., NATS server tarball). |
| extract_path | String | Yes | Path to the binary within the downloaded archive (e.g., `nats-server-v2.11.1-linux-amd64/nats-server`). |
| output_path | String | Yes | Destination path for the binary in the package (e.g., `/usr/bin/nats-server`). |

### custom_steps Array

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | String | Yes | Type of step (currently only `command` is supported). |
| command | String | Yes | Shell command to execute (e.g., `protoc ...`). |

### config_files Array

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| source | String | Yes | Path to the source file (e.g., `packaging/core/config/core.json`). |
| dest | String | Yes | Destination path in the package (e.g., `/etc/serviceradar/core.json`). |
| optional | Boolean | No | If `true`, skip the file if it doesn't exist (e.g., for `api.env`). Defaults to `false`. |

### systemd_service Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| source | String | Yes | Path to the systemd service file (e.g., `packaging/core/systemd/serviceradar-core.service`). |
| dest | String | Yes | Destination path in the package (e.g., `/lib/systemd/system/serviceradar-core.service`). |

### postinst and prerm Objects

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| source | String | Yes | Path to the script (e.g., `packaging/core/scripts/postinstall.sh`). |

## Using the Build System

The `setup-package.sh` script builds Debian and RPM packages based on the `components.json` configuration.

### Prerequisites

- **Tools**: jq (for JSON parsing), docker (for Docker-based builds), go (for Go components), npm (for web component), protoc (for Rust components with protobuf).

- **Directory Structure**:
    - `packaging/components.json`: Configuration file.
    - `packaging/<component>/`: Component-specific files (e.g., `config/`, `systemd/`, `scripts/`).
    - `docker/deb/` and `docker/rpm/`: Dockerfiles for Debian and RPM builds.
    - `cmd/checkers/<checker>/`: Dockerfiles for checkers like rperf-client, rperf-server, sysmon.

### Running the Build

```bash
# Build a single component (Debian)
./scripts/setup-package.sh --type=deb core

# Build a single component (RPM)
./scripts/setup-package.sh --type=rpm sysmon

# Build all components (Debian)
./scripts/setup-package.sh --type=deb --all

# Build all components (RPM)
./scripts/setup-package.sh --type=rpm --all
```

### Output

- Debian packages: `release-artifacts/<package_name>_<version>.deb`
- RPM packages: `release-artifacts/rpm/<version>/<package_name>-<version>-<release>.<arch>.rpm`

### Environment Variables

- **VERSION**: Overrides the version field in components.json (e.g., `VERSION=1.0.33 ./scripts/setup-package.sh ...`).

## Adding a New Component

To add a new component (e.g., a new checker or service), follow these steps:

### 1. Create Packaging Files:

Create a directory `packaging/<component_name>/` with subdirectories:
- `config/`: Configuration files (e.g., `<component_name>.json` or `<component_name>.json.example`).
- `systemd/`: Systemd service file (e.g., `serviceradar-<component_name>.service`).
- `scripts/`: `postinst.sh` and `prerm.sh` for post-install and pre-removal tasks.

Example for a new checker `new-checker`:
```
packaging/new-checker/
├── config/
│   └── new-checker.json.example
├── systemd/
│   └── serviceradar-new-checker.service
└── scripts/
    ├── postinst.sh
    └── prerm.sh
```

### 2. Add to components.json:

Add a new entry to the `components.json` array.

Example for `new-checker` (Go-based):
```json
{
  "name": "new-checker",
  "package_name": "serviceradar-new-checker",
  "version": "1.0.33",
  "description": "ServiceRadar New Checker",
  "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
  "architecture": "amd64",
  "section": "utils",
  "priority": "optional",
  "deb": {
    "depends": ["systemd"],
    "dockerfile": null
  },
  "rpm": {
    "depends": ["systemd"],
    "dockerfile": "docker/rpm/Dockerfile.rpm.simple",
    "release": "1"
  },
  "binary": {
    "source_path": "cmd/checkers/new-checker",
    "build_method": "go",
    "output_path": "/usr/local/bin/serviceradar-new-checker"
  },
  "config_files": [
    {
      "source": "packaging/new-checker/config/new-checker.json.example",
      "dest": "/etc/serviceradar/checkers/new-checker.json.example"
    }
  ],
  "systemd_service": {
    "source": "packaging/new-checker/systemd/serviceradar-new-checker.service",
    "dest": "/lib/systemd/system/serviceradar-new-checker.service"
  },
  "postinst": {
    "source": "packaging/new-checker/scripts/postinst.sh"
  },
  "prerm": {
    "source": "packaging/new-checker/scripts/prerm.sh"
  },
  "conffiles": [
    "/etc/serviceradar/checkers/new-checker.json"
  ]
}
```

### 3. Create Source Code:

Add the component's source code (e.g., `cmd/checkers/new-checker/main.go` for a Go-based checker).

If using Docker or Rust, create a Dockerfile in `cmd/checkers/new-checker/` or `docker/deb/` and update the `deb.dockerfile` and `rpm.dockerfile` fields.

### 4. Test the Build:

```bash
./scripts/setup-package.sh --type=deb new-checker
./scripts/setup-package.sh --type=rpm new-checker
```

### 5. Update Other Scripts:

If using `buildAll.sh` or `buildServiceRadar.sh`, ensure they include the new component in their logic or rely on `--all`.