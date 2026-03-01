---
title: Docker Setup
---

# Docker Setup

Use Docker Compose to run the full ServiceRadar platform stack (core-elx, agent-gateway, web-ng, NATS JetStream, CNPG) with mTLS enabled by default.

## Quick Start

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar
cp .env.example .env

docker compose pull
docker compose up -d

# Get your admin password
docker compose logs config-updater | grep "Password:"
```

Access ServiceRadar at http://localhost (Caddy). Log in with `root@localhost` and the password from the logs. The API is available at http://localhost/api (via proxy) or http://localhost:8090.

## Common Commands

```bash
# View service status
docker compose ps

# Follow logs
docker compose logs -f

# Restart core-elx
docker compose restart core-elx

# Stop the stack
docker compose down
```

## Update an Existing Stack

```bash
# Optional: pin a release or commit
export APP_TAG=v1.0.77

# Pull and restart
docker compose pull
docker compose up -d --force-recreate
```

If you already have a CNPG data volume from a previous install, note that the
stack now stores database credentials in the `cnpg-credentials` volume to avoid
shipping static passwords. Seed the credentials once before restarting:

```bash
docker compose run --rm \
  -e CNPG_PASSWORD=<app-password> \
  -e CNPG_SUPERUSER_PASSWORD=<postgres-password> \
  -e CNPG_SPIRE_PASSWORD=<spire-password> \
  db-credentials
```

## Certificates and TLS

The stack auto-generates mTLS certificates on first boot. Certificates live in the `cert-data` volume and are mounted into each service as needed.
SPIFFE/SPIRE is Kubernetes-only; Docker Compose uses the built-in certificate generator instead.

If you need to verify cert generation:

```bash
docker compose logs cert-generator
docker compose logs cert-permissions-fixer
```

## Device Enrichment Rule Overrides

Core loads built-in enrichment rules from `priv/device_enrichment/rules/*.yaml` and optional filesystem overrides from `/var/lib/serviceradar/rules/device-enrichment/*.yaml`.

Docker Compose mounts this path from your host by default:

- Host: `./docker/compose/rules/device-enrichment`
- Container: `/var/lib/serviceradar/rules/device-enrichment` (read-only)

Use it to override built-in rule IDs or add new rules:

```bash
# Optional: point at a different host directory
export DEVICE_ENRICHMENT_RULES_DIR_HOST=/path/to/device-enrichment-rules

# Restart core after editing rule files
docker compose up -d --force-recreate core-elx
docker compose logs core-elx | rg "Device enrichment rules loaded"
```

UI management:

- Open **Settings → Network → Device Enrichment**.
- Create/edit/delete typed rules (no raw YAML required).
- The UI writes files to the mounted rules directory.
- Restart/reload `core-elx` after edits so runtime rule cache refreshes.

Rollback to built-in behavior:

```bash
# Disable host overrides by pointing at an empty directory
mkdir -p /tmp/serviceradar-empty-rules
export DEVICE_ENRICHMENT_RULES_DIR_HOST=/tmp/serviceradar-empty-rules
docker compose up -d --force-recreate core-elx
```

## Troubleshooting

- **Web UI not reachable**: Ensure Caddy is running (`docker compose ps`) and check its logs (`docker compose logs caddy`).
- **Core API not reachable**: Verify `core-elx` is healthy and listening on port 8090 (`docker compose logs core-elx`).
- **Database issues**: Confirm CNPG is healthy (`docker compose logs cnpg`).
- **Agent not enrolling**: Check `docker compose logs agent` for a successful connection to `agent-gateway.serviceradar:50052` and verify the gateway logs show `Agent enrolled` (`docker compose logs agent-gateway`).
