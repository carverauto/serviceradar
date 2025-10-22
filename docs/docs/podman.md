# ServiceRadar Podman Guide (Oracle Linux 9)

Podman can run the ServiceRadar container stack without Docker. This guide covers the required packages and startup commands that we have validated on Oracle Linux 9.

## Requirements

- Oracle Linux 9 (or another RHEL 9 derivative with Podman 4.6+)
- `podman`, `podman-docker`, and the Docker Compose plugin (`docker-compose-plugin`)
- Optional but recommended: `podman-compose` 1.0.6+ (Python wrapper) for legacy workflows
- 8 GiB RAM and 50 GiB free disk space (matches the Docker baseline)

> **Why rootful Podman?**  
> ServiceRadar containers request `NET_ADMIN`, `IPC_LOCK`, and `SYS_NICE` capabilities plus high ulimits. Those are blocked in rootless Podman today, so run the stack with `sudo` (rootful pods) until we can relax the requirements.

## Install Podman and Compose bits

```bash
sudo dnf install -y podman podman-docker docker-compose-plugin podman-compose

# Optional sanity checks
podman --version
podman compose version
podman-compose version
```

The `podman-docker` package provides a `/usr/bin/docker` shim. ServiceRadar’s tooling does not rely on that shim after this change, but keeping it installed prevents other scripts from failing if they still shell out to `docker`.

## Starting ServiceRadar with Podman

Clone the repository if you have not already:

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
```

Use the `CONTAINER_ENGINE` override that is now supported by `Makefile.docker`:

```bash
# Preserve CONTAINER_ENGINE for sudo by using -E
sudo -E CONTAINER_ENGINE=podman make -f Makefile.docker start
```

The `start` target runs the same workflow we use for Docker: generate mTLS material, render config, and bring up the long-running services with `podman compose up -d`.

Common follow-up commands (all accept `CONTAINER_ENGINE=podman`):

```bash
sudo -E CONTAINER_ENGINE=podman make -f Makefile.docker status
sudo -E CONTAINER_ENGINE=podman make -f Makefile.docker logs
sudo -E CONTAINER_ENGINE=podman make -f Makefile.docker down
```

If you prefer raw Compose invocations:

```bash
sudo -E podman compose up -d
sudo -E podman compose --profile full up -d
sudo -E podman compose down
```

The Python `podman-compose` front end also works and correctly handles our `depends_on.condition` chain:

```bash
sudo -E podman-compose up -d
```

## Registry authentication

Pulling public images from GHCR does not require credentials. If you need to push local builds, authenticate with Podman:

```bash
podman login ghcr.io
```

`podman login` stores credentials in `${XDG_RUNTIME_DIR}/containers/auth.json`; Docker-compatible tooling in the repo will respect that file through the `podman-docker` shim.

## Troubleshooting tips

- **`Error: unknown flag: --profile`** – Install the `docker-compose-plugin` package so `podman compose` uses the Docker Compose V2 provider.
- **`error adding capabilities: operation not permitted`** – Switch to rootful Podman (use `sudo`) or drop the capability from the service definition.
- **Pods stuck starting** – Check the one-shot jobs (`cert-generator`, `config-updater`, etc.) via `podman logs serviceradar-config-updater`. Those must complete before core/web start.
- **Networking issues** – Podman names the network `serviceradar-net` automatically. Destroy stale networks with `podman network rm serviceradar-net` and rerun `make ... start`.

Let us know in GH issue #1855 if you hit configuration gaps so we can extend automation or relax rootful requirements in a follow-up iteration.
