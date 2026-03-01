---
title: Tools Pod (serviceradar-tools)
---

# Tools Pod (serviceradar-tools)

`serviceradar-tools` is a preconfigured debugging environment shipped with ServiceRadar. Use it for safe, repeatable operational commands without installing local tooling.

## What You Get

- `nats` CLI with a preloaded context (TLS and credentials)
- `psql` helpers for CNPG (Timescale + AGE)
- Common utilities: `jq`, `rg`, `openssl`, `nc`

## Kubernetes Usage

Open a shell:

```bash
kubectl -n <namespace> exec -it deploy/serviceradar-tools -- bash
```

Common NATS checks:

```bash
# Streams
nats stream ls

# Events stream details
nats stream info events

# Consumers (events)
nats consumer ls events
```

CNPG checks:

```bash
cnpg-info
cnpg-sql "SELECT now();"
```

## How It Is Configured

The tools pod mounts:

- mTLS client certs under `/etc/serviceradar/certs`
- CNPG CA and credentials under `/etc/serviceradar/cnpg`
- NATS context JSON under `/root/.config/nats/context/`

On startup it prints a MOTD with available aliases and selects the `serviceradar` NATS context.

## Where It Lives In This Repo

- Helm: `helm/serviceradar/files/serviceradar-tools.yaml`
- Docker/Compose tooling image: `docker/compose/Dockerfile.tools`, `docker/compose/tools-profile.sh`, `docker/compose/tools-motd.txt`

Note: Docker Compose uses the same tools image for bootstrap jobs; Kubernetes runs a long-lived `serviceradar-tools` pod for interactive debugging.
