---
title: Docker Setup
---

# Docker Setup

Use Docker Compose to run the full ServiceRadar platform stack (core-elx, agent-gateway, web-ng, datasvc, nats, cnpg) with mTLS enabled by default.

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

If you need to verify cert generation:

```bash
docker compose logs cert-generator
docker compose logs cert-permissions-fixer
```

## Troubleshooting

- **Web UI not reachable**: Ensure Caddy is running (`docker compose ps`) and check its logs (`docker compose logs caddy`).
- **Core API not reachable**: Verify `core-elx` is healthy and listening on port 8090 (`docker compose logs core-elx`).
- **Database issues**: Confirm CNPG is healthy (`docker compose logs cnpg`).
- **Agent not enrolling**: Check `docker compose logs agent` for a successful connection to `agent-gateway.serviceradar:50052` and verify the gateway logs show `Agent enrolled` (`docker compose logs agent-gateway`).
