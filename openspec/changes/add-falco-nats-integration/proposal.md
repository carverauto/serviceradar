# Proposal: add-falco-nats-integration

## Summary

Integrate Falco runtime security events into ServiceRadar's NATS JetStream ingestion pipeline,
enabling centralized security observability across fleets of Kubernetes clusters. Falcosidekick
connects directly to NATS using JWT `.creds` file authentication.

## Problem

Falco detects runtime threats (container escapes, privilege escalation, unexpected network activity,
etc.) but its alerts stay local unless forwarded. Organizations running Falco across hundreds of
clusters need a way to centralize these events for correlation, alerting, and visualization alongside
their existing ServiceRadar monitoring data.

## Prerequisite: Falcosidekick NATS `.creds` Support

Falcosidekick's NATS output currently only supports `hostport`, `mutualtls`, `checkcert`, and
`subjecttemplate`. It lacks support for NATS `.creds` files (JWT + NKey auth), custom CA cert paths,
and custom client cert/key paths.

**We will contribute `.creds` file support upstream to Falcosidekick's NATS output.** This adds:
- `nats.credsfile` — path to a NATS `.creds` file for JWT authentication
- `nats.cacertfile` — path to a CA certificate for server TLS verification

This proposal assumes Falcosidekick has been patched with these capabilities.

## Goals

1. Get Falco events flowing into NATS JetStream on `events.falco.raw`
2. Use the existing NATS JWT credential onboarding pipeline (no static NATS config changes)
3. Support multi-cluster fleets: each cluster gets its own enrollment, credentials, and identity
4. Secure transport: TLS to NATS with JWT-based authorization via `.creds` files
5. Document the setup for new users in `docs/docs/`

## Non-Goals (follow-up proposals)

- Elixir event processor for Falco events (db-event-writer integration)
- Database schema / hypertable for security events
- UI views for Falco alerts
- OCSF normalization of Falco events

## Approach

### Architecture

```
[Each Remote Cluster]                              [ServiceRadar Cluster]
+------------------+    +-------------------+          +------------------+
| Falco DaemonSet  |--->| Falcosidekick     |--NATS--->| NATS JetStream   |
| (kernel events)  |    | (nats output      |  .creds  | (events stream)  |
+------------------+    |  + .creds auth)   |  + TLS   +------------------+
                        +-------------------+
                          Onboarded via existing
                          CollectorPackage pipeline
```

No relay. No sidecar. Falcosidekick talks directly to NATS with JWT auth.

### Falcosidekick Configuration

```yaml
nats:
  hostport: "nats://nats.serviceradar.example.com:4222"
  subjecttemplate: "events.falco.raw"
  minimumpriority: "warning"
  checkcert: true
  cacertfile: "/etc/serviceradar/certs/ca-chain.pem"
  credsfile: "/etc/serviceradar/creds/nats.creds"
```

### NATS Subject & Permissions

- **Publish subject**: `events.falco.raw`
- **Collector type**: `:falcosidekick`
- **Permissions**: `publish.allow: ["events.falco.>"]`, `subscribe.allow: ["_INBOX.>"]`

### Onboarding Flow

Uses the existing `CollectorPackage` pipeline:
1. Admin creates a `falcosidekick` collector package in the UI/API
2. `ProvisionCollectorWorker` generates NATS JWT credentials via `AccountClient.generate_user_credentials()`
3. Bundle includes: `nats.creds` + `certs/ca-chain.pem`
4. Enrollment token is used to download the bundle on the target cluster
5. Mount creds + CA cert into the Falcosidekick pod via K8s Secrets

### NATS Stream Compatibility

The existing `events` JetStream stream already includes `events.>` as a subject.
`events.falco.raw` is covered — no stream configuration changes needed.

## Impact

- **Upstream PR**: Add `credsfile` and `cacertfile` to Falcosidekick's NATS output
- **New collector type**: `:falcosidekick` in `ProvisionCollectorWorker.build_permissions_for_collector/1`
- **New bundle template**: Falcosidekick config in `CollectorBundleGenerator`
- **Docs**: `docs/docs/falco-integration.md` — setup guide for new users
- **NATS**: No config changes needed (JWT user onboarding handles auth)
