---
title: ServiceRadar Cluster
---

# ServiceRadar Cluster

The ServiceRadar demo cluster bundles the core platform services into a single Kubernetes namespace so you can explore the full data path end to end. Use this page when you need to understand which workloads are running, how they communicate, and where to look during incident response.

## Core Services

| Component | Purpose | Default Deployment |
|-----------|---------|--------------------|
| Core API | Accepts poller reports, exposes the public API, and fans out notifications. | `deploy/serviceradar-core` |
| Poller | Coordinates health checks against agents and external targets. | `deploy/serviceradar-poller` |
| Sync | Ingests metadata from external systems (e.g., NetBox, Armis) and keeps the registry current. | `deploy/serviceradar-sync` |
| Registry | Stores canonical device inventory and service relationships. | `statefulset/serviceradar-registry` |
| KV | Provides dynamic configuration via NATS JetStream. | `statefulset/serviceradar-datasvc` |
| Web UI | Serves dashboards and embeds SRQL explorers. | `deploy/serviceradar-web` |

Each deployment surfaces the `serviceradar.io/component` label; use it to filter logs and metrics when debugging clustered issues.

## Supporting Data Plane

- **Proton / Timeplus**: Stateful ingestion of high-volume telemetry such as traps and streaming metrics. Deployed as `statefulset/serviceradar-proton` with an attached PVC.
- **Faker**: Generates synthetic Armis datasets for demos and developer testing. Deployed as `deploy/serviceradar-faker` and backed by `pvc/serviceradar-faker-data`.
- **Ingress**: The `serviceradar-gateway` service exposes HTTPS endpoints for the web UI and API; mutual TLS is enforced between internal components via `serviceradar-ca`.

## Observability Hooks

- **Logs**: All pods write to STDOUT/STDERR; aggregate with `kubectl logs -n demo -l serviceradar.io/component=<name>`.
- **Metrics**: Pollers scrape Sysmon VM exporters every 60 seconds; ensure the jobs stay within the five-minute hostfreq retention window.
- **Tracing**: Distributed traces flow through the OTLP gateway (`service/serviceradar-otel`) and land in Proton for correlation with SRQL queries.

## Operational Tips

- Use `kubectl get pods -n demo` to verify rollouts. Most deployments support at least two replicas; scale `serviceradar-sync` during heavy reconciliation.
- Persistent stores (`registry`, `kv`, `proton`, `faker`) rely on PVCs; confirm volume mounts before recycling pods.
- The demo namespace is designed for experimentation. When you need a clean slate, follow the runbooks in `agents.md` to reset Faker, truncate Proton tables, and rebuild materialized views.

For component-specific configuration, see the guides under **Deployment** and **Get Data In**.
