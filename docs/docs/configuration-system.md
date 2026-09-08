---
title: Configuration & KV Store
---

# Configuration & KV Store

ServiceRadar services are configured through two layers:

1. **File-based config** — a JSON or TOML file on disk for each service.
2. **A NATS key/value (KV) layer** — a centralized store, served by the
   `datasvc` service, that lets you distribute and override configuration
   without redeploying.

Most operators start with file-based config and adopt the KV layer as a
deployment grows. This page explains how the two layers fit together and how to
inspect or change a service's configuration.

## File-based configuration

Every ServiceRadar service reads a config file from `/etc/serviceradar`. Common
examples:

| Service | Config file |
|---------|-------------|
| Core | `core.json` |
| Gateway | `gateway.json` |
| Agent | `agent.json` |
| Datasvc | `datasvc.json` |
| Trapd (SNMP traps) | `trapd.json` |
| Flowgger (syslog/flow) | `flowgger.toml` |
| rperf checker | `checkers/rperf.json` |

In Kubernetes, these files are delivered through the `serviceradar-config`
ConfigMap and mounted into each pod. On standalone hosts, they live directly on
disk and are owned by the `serviceradar` user.

The config file is always the **base layer**. If the KV layer is disabled, the
file is the complete configuration.

## The KV store (datasvc)

The KV store is provided by the **`datasvc`** service. It exposes a gRPC
`KvService` API (default address `serviceradar-datasvc:50057`) backed by a NATS
JetStream KV bucket named **`serviceradar-datasvc`**.

`datasvc` also serves an object bucket (`serviceradar-objects`) for larger
artifacts. KV entries default to a `24h` history/TTL window and the bucket has a
configurable maximum size.

Configuration is stored in the KV bucket under stable, well-known keys. Each
managed service has a descriptor that defines its key — for example:

| Service | KV key |
|---------|--------|
| Core | `config/core.json` |
| Datasvc | `config/datasvc.json` |
| Trapd | `config/trapd.json` |
| Flowgger | `config/flowgger.toml` |
| OTEL collector | `config/otel.toml` |
| rperf checker | `config/rperf-checker.json` |

Scoped services use a templated key that includes an identity. For example a
gateway's config lives at `config/gateways/{gateway_id}.json`, an agent's at
`config/agents/{agent_id}.json`, and per-agent checkers at
`agents/{agent_id}/checkers/<kind>/<kind>.json`.

## Connecting to the KV layer

A service is told to use the KV layer through environment variables. In the Helm
chart these are emitted automatically when `kv.enabled` is true:

| Variable | Purpose |
|----------|---------|
| `CONFIG_SOURCE` | Config source selector (`file` is the default). |
| `KV_ADDRESS` | Datasvc gRPC address (default `serviceradar-datasvc:50057`). |
| `KV_SEC_MODE` | `mtls`, `spiffe`, or `none` (production uses `mtls`). |
| `KV_CERT_DIR` | Directory holding KV client certificates. |
| `KV_CERT_FILE` / `KV_KEY_FILE` / `KV_CA_FILE` | mTLS materials for the KV connection. |
| `KV_TRUST_DOMAIN` / `KV_WORKLOAD_SOCKET` | SPIFFE settings, used when `KV_SEC_MODE` is `spiffe`. |
| `KV_SERVER_NAME` / `KV_SERVER_SPIFFE_ID` | Expected server identity for verification. |

On standalone hosts these are set in the systemd unit for each service. For
example, the rperf checker unit ships with:

```
Environment="CONFIG_SOURCE=file"
Environment="KV_ADDRESS=127.0.0.1:50057"
Environment="KV_SEC_MODE=mtls"
Environment="KV_CERT_DIR=/etc/serviceradar/certs"
...
EnvironmentFile=-/etc/serviceradar/kv-overrides.env
```

### `kv-overrides.env`

The systemd units load an optional `EnvironmentFile`,
`/etc/serviceradar/kv-overrides.env`. The leading `-` makes it optional, so the
file does not have to exist. When present, any `KEY=value` lines it contains
override the defaults baked into the unit — use it to point a host at a
different `KV_ADDRESS`, change `KV_SEC_MODE`, or adjust certificate paths
without editing the unit file itself.

## Config precedence

The configuration layers are applied in order, from lowest to highest priority:

1. **On-disk config file** — the base configuration.
2. **KV overlay** — values pulled from the service's KV key are deep-merged on
   top of the file config. The merge is recursive: keys present in the overlay
   replace the corresponding file values, while keys absent from the overlay are
   left untouched.
3. **Pinned overlay** — Rust services support an optional pinned file
   (`PINNED_CONFIG_PATH`) that is overlaid **last**, so sensitive local values
   always win over both the file and KV.

The deep-merge behavior means a KV overlay can be a small JSON document that
changes only the fields you care about; it does not need to be a full copy of
the config.

## Seeding and syncing config

KV entries are populated and kept current through two mechanisms.

### Seeding

When a deployment is first installed, the file-based config is **seeded** into
the KV bucket so the central store has a starting value. In Helm this is driven
by bootstrap Jobs and the `configSync` settings. The relevant environment
variables are:

| Variable | Meaning |
|----------|---------|
| `CONFIG_SYNC_ENABLED` | Whether config sync runs at all for this service. |
| `CONFIG_SYNC_SEED` | Seed the file config into KV if the key is absent. |
| `CONFIG_SYNC_WATCH` | Watch the KV key and re-apply changes at runtime. |
| `CONFIG_KV_KEY` | Override the KV key for this service. |
| `CONFIG_SYNC_ROLE` | Role used when seeding/syncing. |

Seeding is idempotent: it does not clobber a key that already has a value, so
running it again is safe.

### config-bootstrap

ServiceRadar's Rust services use the `config-bootstrap` library to load
configuration. Its lifecycle is:

1. Read the config file from disk (JSON or TOML).
2. Overlay the pinned file (if `PINNED_CONFIG_PATH` is set) so sensitive values
   win over defaults.

This gives Rust and Go services a consistent, file-first loading path. The KV
overlay is layered on top of this base by the service's startup wiring when KV
is enabled.

## Inspecting and updating a service's config

To see what a service is actually running with, check both layers:

1. **The file** — read the on-disk config (`/etc/serviceradar/<service>.json`
   or the `serviceradar-config` ConfigMap in Kubernetes).
2. **The KV overlay** — read the service's KV key from `datasvc`. Because the
   effective config is `file` deep-merged with the KV value, the KV entry shows
   exactly which fields are being overridden centrally.

To change configuration:

- **For a file-only deployment**, edit the config file and restart the service.
  On Kubernetes, update the `serviceradar-config` ConfigMap (or your Helm
  values) and roll the pod.
- **For a KV-managed deployment**, write the changed fields to the service's KV
  key. If the service runs with `CONFIG_SYNC_WATCH` enabled it will pick up the
  change without a restart; otherwise restart the service so it re-reads the
  overlay.

The `serviceradar edge package create` command accepts a `--datasvc-endpoint`
flag for pointing onboarding workflows at a specific datasvc/KV endpoint — see
the [ServiceRadar CLI](./cli-reference.md) reference.

> **Note:** ServiceRadar's KV layer is backed by **NATS JetStream**, served by
> `datasvc`. It does not use Redis or ClickHouse for configuration storage. If
> you encounter older documentation describing a Redis- or ClickHouse-based
> config store, it is out of date.
