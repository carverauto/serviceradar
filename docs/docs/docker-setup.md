---
title: Docker Setup
---

# Docker Setup

Use Docker Compose to run the full ServiceRadar platform stack (core-elx, agent-gateway, web-ng, NATS JetStream, CNPG) with mTLS enabled by default.

## Quick Start

```bash
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar

# Pin a published release tag or published sha tag.
# Unset APP_TAG defaults to the moving `latest` tag, which is not reproducible.
export APP_TAG=<published-release-tag>

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
# Pin a published release or published sha tag.
export APP_TAG=<published-release-tag>

# Pull and restart
docker compose pull
docker compose up -d --force-recreate
```

If you already have a CNPG data volume from a previous install, note that the
stack now stores database credentials in the `cnpg-credentials` volume to avoid
shipping static passwords. Legacy pre-security Compose volumes are recovered
automatically using the old defaults on first restart.

Docker Compose now auto-migrates an existing PG16 CNPG data volume to PG18
during startup. For existing installs, the normal path remains:

```bash
docker compose pull
docker compose up -d
```

Fresh installs and already-migrated PG18 volumes automatically no-op in the
migration step.

Current compose defaults store generated NATS runtime credentials in the named
`nats-creds` volume, so `docker compose down -v` gives you a clean bootstrap for
that state. If you are upgrading from an older checkout that wrote runtime
credentials into `./docker/compose/creds`, clear that directory once before
retrying so stale partial bootstrap files are not copied back in as seed data.

If the old install used non-default credentials without a persisted
`cnpg-credentials` volume, or if you want to run the migration explicitly, the
standalone helper is still available:

```bash
./docker/compose/migrate-cnpg-pg16-to-pg18.sh
```

If you use custom credentials or lost a newer `cnpg-credentials` volume, seed
the credentials once before restarting:

```bash
docker compose run --rm \
  -e CNPG_SUPERUSER=<postgres-or-legacy-superuser> \
  -e CNPG_PASSWORD=<app-password> \
  -e CNPG_SUPERUSER_PASSWORD=<postgres-password> \
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

## Optional NetFlow and IP Enrichment Jobs

Docker Compose disables the heavyweight NetFlow/IP enrichment maintenance
schedulers by default. This keeps a fresh single-node stack responsive for
diagnostics, MTR, device management, and normal UI use when no flow collection is
configured.

Enable these only when the Docker host has enough Postgres headroom and you are
actually collecting flows:

```bash
export IP_ENRICHMENT_SCHEDULER_ENABLED=true
export GEOLITE_MMDB_SCHEDULER_ENABLED=true
export IPINFO_MMDB_SCHEDULER_ENABLED=true
export NETFLOW_ENRICHMENT_DATASET_SCHEDULER_ENABLED=true
export NETFLOW_SECURITY_SCHEDULER_ENABLED=true
export NETFLOW_CACHE_SCHEDULER_ENABLED=true
docker compose up -d --force-recreate core-elx
```

## Troubleshooting

- **Web UI not reachable**: Ensure Caddy is running (`docker compose ps`) and check its logs (`docker compose logs caddy`).
- **Core API not reachable**: Verify `core-elx` is healthy and listening on port 8090 (`docker compose logs core-elx`).
- **Database issues**: Confirm CNPG is healthy (`docker compose logs cnpg`).
- **Agent not enrolling**: Check `docker compose logs agent` for a successful connection to `agent-gateway.serviceradar:50052` and verify the gateway logs show `Agent enrolled` (`docker compose logs agent-gateway`).
