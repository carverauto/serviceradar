# Change: Add self-hosted CNPG backups via SeaweedFS + barman-cloud plugin

## Why
ServiceRadar's CNPG Postgres clusters currently have **no backups**: the demo
`demo/cnpg` cluster (and every tenant cluster the chart renders) has an empty
`spec.plugins`/`spec.backup`, so WAL is retained only on the primary's local
`pg_wal`/replication slot. This is the exact failure mode behind the 2026-06-17
demo outage — a lagging replica's slot retained WAL until the local-path data
volume filled and the primary crashed, with no off-volume copy to recover from.
A re-cloning replica that falls behind also hits `requested WAL segment has
already been removed` with no archive to fetch the missing segment from.

CNPG 1.26+ **removed** the in-tree `barmanObjectStore`, so object-store backups
now require the separate **barman-cloud plugin** (`barman-cloud.cloudnative-pg.io`)
and its `ObjectStore` CRD — neither is installed. The decision is to host the S3
target **in-cluster** with **SeaweedFS** (Apache-2.0) on a **Longhorn** PVC, so
backups land on replicated, network-attached storage in a different fault domain
than the Postgres data disks, with **no paid cloud object storage**. This must
also fit the instance-per-tenant SaaS model (dedicated CNPG per tenant) with
per-tenant backup isolation.

## What Changes
- **NEW capability `cnpg-backups`**: continuous WAL archiving to an object store,
  scheduled base backups with retention, point-in-time recovery (PITR), replica
  rebuild from archive, per-tenant isolation, and secure-by-default opt-in.
- Deploy **SeaweedFS** (master + volume + filer + S3 gateway) in a dedicated
  namespace, backed by a **Longhorn** PVC, exposing an in-cluster S3 endpoint
  (`http://<svc>:8333`, path-style). Rendered by a new gated chart template.
- Install the **barman-cloud plugin** (pinned release) into `cnpg-system`
  (cluster-scoped operator infra — NOT vendored into the per-tenant chart's
  `crds/`). This installs the `objectstores.barmancloud.cnpg.io` CRD.
- Add chart templating (gated behind a new `cnpg.backup.enabled` value, **off by
  default**): an `ObjectStore` CR, a `spec.plugins[]` WAL-archiver block on the
  `Cluster`, and a `ScheduledBackup` — all per-tenant via `serverName`/bucket.
- Per-tenant isolation: **bucket-per-tenant** with **scoped S3 credentials** (one
  access/secret key per tenant, whole-bucket-scoped), each in the tenant
  namespace; never a shared key with path prefixes.
- NetworkPolicy so only CNPG instance pods (which run the barman WAL-archiver
  **sidecar**) reach the SeaweedFS S3 port; the in-SeaweedFS traffic stays open.
- Operational runbook for restore/clone/PITR, capacity planning, and a standing
  restore drill. Document the Longhorn off-cluster BackupTarget needed so the
  backup store itself is not an un-backed-up single point of failure.

## Impact
- Affected specs:
  - `cnpg-backups` (new capability)
- Affected code:
  - `helm/serviceradar/templates/cnpg-cluster.yaml` (add gated `spec.plugins[]`)
  - `helm/serviceradar/templates/cnpg-backup.yaml` (NEW: ObjectStore + ScheduledBackup)
  - `helm/serviceradar/templates/seaweedfs.yaml` (NEW: Secret/PVC/Deployment/Service) or a separate SeaweedFS ArgoCD app
  - `helm/serviceradar/templates/network-policy.yaml` / `cnpg-application-network-policy.yaml` (allow CNPG → SeaweedFS:8333)
  - `helm/serviceradar/values.yaml` (`cnpg.backup.*` + `seaweedfs.*`, default off)
  - `helm/serviceradar/values-demo.yaml` (opt in once `demo/cnpg` is healthy)
  - `helm/serviceradar/README.md` (backup + recovery docs)
  - cluster-bootstrap layer (`serviceradar-control` repo `k8s/platform/cnpg/`): install the barman-cloud plugin into `cnpg-system` — separate PR, NOT this chart
  - `k8s/argocd/applications/demo-prod.yaml` (verify CNPG `ignoreDifferences` still covers only `/spec/instances` + `/spec/storage/size`; `spec.plugins` is GitOps-managed, not ignored)
