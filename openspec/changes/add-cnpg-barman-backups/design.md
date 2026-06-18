# Design: Self-hosted CNPG backups (SeaweedFS + barman-cloud plugin)

## Context

CNPG operator `ghcr.io/cloudnative-pg/cloudnative-pg:1.27.1` runs in `cnpg-system`
(installed via Helm, not ArgoCD). Live-verified facts:

- **No `objectstores.barmancloud.cnpg.io` CRD** and no barman/seaweedfs/minio
  workloads exist anywhere — backups are not configured for any cluster.
- In-tree `barmanObjectStore` was **removed in CNPG 1.26+**; object-store backups
  now require the separate **barman-cloud plugin** (`barman-cloud.cloudnative-pg.io`).
- **cert-manager** is installed and healthy — the plugin's hard prerequisite is met.
- StorageClasses: `longhorn` (`driver.longhorn.io`, `numberOfReplicas: 2`,
  `allowVolumeExpansion: true`), `longhorn-static`, plus the `local-path*` family.
- `demo/cnpg`: 3 instances on `local-path-cnpg` (500Gi PVCs), **currently
  mid-replica-rebuild (2/3 Ready, "Creating a new replica")**. Backups land
  **off** the DB's own local disk — directly addressing the 2026-06-17 outage.
- Chart model: one `Cluster` per Helm release, name from
  `serviceradar.cnpgClusterName` (`_helpers.tpl:387`, default `cnpg`). Cluster
  template `templates/cnpg-cluster.yaml` already enforces a WAL safety cap
  (`max_slot_wal_keep_size`, default ~30% of storage, demo pinned 250GB).
- ArgoCD app `serviceradar-demo-prod` renders this chart; its CNPG
  `ignoreDifferences` covers only `/spec/instances` and `/spec/storage/size`, so
  adding `spec.plugins` is GitOps-managed and reconciles cleanly.

## Goals

- Continuous WAL archiving + scheduled base backups for CNPG, off the DB's own
  data volume, on replicated storage, with **no paid cloud object storage**.
- Point-in-time recovery and replica-rebuild-from-archive.
- Fit the instance-per-tenant SaaS model with **per-tenant backup isolation**.
- **Secure by default**: backups are opt-in; OSS / single-node installs without
  SeaweedFS render unchanged. Scoped per-tenant credentials, no shared keys.

## Non-Goals

- Migrating demo's CNPG data volumes off `local-path-cnpg` onto Longhorn (its
  single-node local PV remains a SPOF; backups only partially mitigate it — a
  separate decision, flagged in Open Questions).
- Off-cluster / off-site replication of the backup store itself beyond pointing
  Longhorn at an off-cluster BackupTarget (3-2-1 backstop; flagged, not built here).
- Backing up non-CNPG state (NATS, object stores, config) — out of scope.

## Decisions

### Decision 1: SeaweedFS-on-Longhorn as the S3 target (vs MinIO, vs Longhorn-only)

**Chosen:** SeaweedFS (Apache-2.0), running master + volume + filer + standalone
S3 gateway as **4 discrete components** (not `allInOne`), each on its own Longhorn
PVC, in a dedicated namespace (`serviceradar-backups`).

- **vs MinIO:** rejected for community-edition licensing/feature concerns
  (decision already made). SeaweedFS is Apache-2.0 with a native path-style S3
  gateway, which is exactly what barman-cloud's boto3 client needs against a
  non-AWS endpoint.
- **vs Longhorn volume snapshots only:** Longhorn snapshots protect the *data
  volume*, but CNPG/barman gives logical, PITR-capable, WAL-continuous backups
  that survive a corrupt cluster, a bad migration, or accidental `DELETE` — a
  block snapshot cannot do PITR to an arbitrary second. We still recommend a
  Longhorn BackupTarget for the SeaweedFS PVC as the backup-of-the-backup.
- **Discrete components vs `allInOne`:** the byte store (`volume`) and the
  metadata layer (`filer`, leveldb-on-PVC — losing it loses the ability to
  list/restore) get **separate** Longhorn PVCs and blast radii. `allInOne`
  couples metadata + data + gateway into one pod (`updateStrategy: Recreate`),
  acceptable only for a throwaway demo.
- Path-style addressing (`endpoint/bucket/key`) is native — no per-bucket DNS.
  Use DNS-label-safe bucket names (lowercase, no dots) so neither addressing mode
  breaks. Plain HTTP behind a NetworkPolicy is acceptable intra-cluster (matches
  the official MinIO example `http://minio:9000`); TLS via cert-manager +
  `endpointCA` is optional.

### Decision 2: barman-cloud plugin, owned by the cluster-bootstrap layer

**Chosen:** install the **barman-cloud plugin** (pinned release ≥ v0.11.0,
compatible with CNPG ≥ 1.26; pin a digest, do not track `latest`) into
`cnpg-system` via the **cluster-bootstrap layer** (`serviceradar-control` repo,
alongside the CNPG operator), **not** the per-tenant serviceradar chart.

- The plugin is a singleton CNPG-I extension serving ALL tenant clusters; it
  ships one namespaced `barman-cloud` Deployment + the **cluster-scoped**
  `objectstores.barmancloud.cnpg.io` CRD. Installing it from a per-tenant Helm
  release would make N releases fight over one Deployment and a shared CRD.
- **Do NOT vendor the ObjectStore CRD into the chart's `crds/`** (that dir is for
  SPIRE CRDs) — a tenant release could otherwise upgrade/downgrade a
  cluster-shared CRD.
- Correctness footguns baked into templates: the `Cluster.spec.plugins[].name`
  and `pluginConfiguration.name` string is **`barman-cloud.cloudnative-pg.io`**;
  the CRD API group is **`barmancloud.cnpg.io/v1`** (do not confuse them).
  `isWALArchiver: true` is what turns on continuous archiving. Backups use
  `method: plugin`.

### Decision 3: Per-tenant isolation — bucket-per-tenant + scoped credentials

**Chosen:** one bucket per tenant (`sr-backups-<tenantId>`), one **scoped S3
identity** per tenant (whole-bucket `Read`/`Write`/`List`/`Tagging` actions), each
tenant's key in a Secret **in that tenant's namespace** (CNPG only references
secrets in the Cluster's own namespace). One **shared** SeaweedFS cluster, many
isolated buckets — NOT one SeaweedFS per tenant.

- **vs single shared bucket + path prefixes:** rejected. A leaked key from one
  tenant's barman sidecar would expose every tenant's PITR data; offboarding
  becomes a risky recursive prefix delete instead of an atomic `delete bucket`.
- Per-cluster identity is the plugin **`serverName` parameter on the Cluster**
  (default `<tenantId>-<clusterName>`), kept **stable forever** — changing it
  orphans backup history and breaks PITR/WAL continuity. The ObjectStore's
  `serverName` field MUST be left **empty** (in-tree API-compat only).
- Each per-tenant chart render naturally produces its own ObjectStore + scoped
  secret ref + serverName + bucket — no per-tenant template forking.
- Stagger ScheduledBackup cron (hash on `serverName`) so N tenants don't all base
  back up at 02:00 and stampede SeaweedFS. Use `target: prefer-standby` so
  base-backup I/O hits a replica, not the primary.

### Decision 4: S3-compatible checksum compatibility

Recent boto3 data-integrity checksums can break against SeaweedFS/MinIO. If
basebackup/WAL uploads error, set on the ObjectStore
`instanceSidecarConfiguration.env`: `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`
and `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`. WAL/data `compression: gzip`
by default.

## Risks

- **Enabling WAL archiving on an unhealthy cluster.** A failing required WAL
  archiver makes the primary retain WAL locally — the same disk-fill shape as the
  2026-06-17 outage (now bounded by `max_slot_wal_keep_size`, but still alarms).
  **Mitigation:** turn on `isWALArchiver` only when the cluster is `Healthy`; gate
  the demo opt-in on health in the rollout, not in templating. `demo/cnpg` is
  mid-rebuild right now — wait.
- **SeaweedFS/Longhorn loss = backup store gone.** Live clusters keep serving but
  WAL archiving fails and accumulates locally. **Mitigation:** Longhorn
  off-cluster BackupTarget for the SeaweedFS PVC (3-2-1); alert on
  `ContinuousArchiving` condition; watch `max_slot_wal_keep_size` headroom.
- **Plugin-before-chart ordering.** The ObjectStore CR is rejected
  (`no matches for kind ObjectStore`) until the plugin is installed in
  `cnpg-system`. **Mitigation:** bootstrap-layer plugin app syncs first; chart
  already sets `SkipDryRunOnMissingResource=true`.
- **Sidecar egress silently dropped.** The WAL archiver runs *inside* the CNPG
  pod; if NetworkPolicy doesn't permit CNPG → SeaweedFS:8333, backups fail
  silently. **Mitigation:** explicit egress/ingress rule + a verified first backup.
- **A backup never restored is not a backup.** **Mitigation:** standing weekly
  restore drill into a throwaway namespace asserting PITR to a known timestamp.

## Migration

- Greenfield: no existing object store to migrate from; no in-tree
  `barmanObjectStore` config exists to convert.
- Rollout order (live): (1) install barman-cloud plugin into `cnpg-system`;
  (2) deploy SeaweedFS + its `seaweedfs-s3-config` Secret + bucket; (3) create the
  tenant-namespace S3 creds Secret; (4) apply the `ObjectStore`; (5) enable the
  Cluster `plugins[]` archiver; (6) apply the `ScheduledBackup`; (7) verify WAL
  archiving + a base backup + a test PITR.
- The retired `endpoint_inventory_addon_package_seeder` and the unrelated repo
  `objectStoreRetention.*` keys (NATS/datasvc agent-release GC) MUST NOT be
  overloaded for this.

## Open Questions

1. Should demo's CNPG **data** volumes move from `local-path-cnpg` to `longhorn`
   too? The single-node local PV is itself a SPOF the backups only partially
   mitigate. (Recommend yes, separate change.)
2. Secret delivery for per-tenant scoped S3 keys: sealed-secrets vs
   external-secrets. (Repo uses sealed-secrets per memory notes — default to that.)
3. Longhorn replica count for the SeaweedFS `volume` PVC: keep `2` (2× raw cost,
   protects a backup mid-incident) or drop to `1` via a custom StorageClass
   (backups are themselves a redundant copy). (Recommend 2 for the store metadata,
   reconsider for very large volume PVCs.)
4. Premium-tier second ObjectStore for an off-cluster copy — defer until a second
   self-hosted store exists.

## Future Work: SaaS control-plane & tenant-console integration

Out of scope for this change (which builds the backend capability + the demo
proving ground), but the design is deliberately shaped so the SaaS control plane
(`serviceradar-control`, Phoenix LiveView) can drive backups later **without
rework**. The hooks already exist in the changes that repo is building:

- **Backups as a plan entitlement** — `serviceradar-control`'s
  `add-tenant-plan-tiers-and-entitlements` gates what the platform provisions per
  tier. Backup *retention window*, *PITR depth*, and *base-backup frequency*
  become entitlement parameters (e.g. free/dev = short or none; paid = longer
  retention + deeper PITR). This change keeps every one of those a per-Cluster
  input (Decision 3: `serverName`, bucket, `ScheduledBackup` cron, retention), so
  the entitlement layer parameterizes them rather than forking templates.
- **Control-plane provisions it** — `add-control-plane-foundations` already
  auto-provisions a dedicated per-tenant ServiceRadar instance + CNPG on the
  shared cluster. Backups extend that same provisioning step: when the control
  plane renders a tenant's Cluster, it also creates that tenant's bucket on the
  shared SeaweedFS, the tenant-namespace scoped S3 creds Secret, the `ObjectStore`,
  and the `ScheduledBackup` — exactly the artifacts this change templates, just
  emitted by the control plane per the tenant's entitlement.
- **Tenant-console surface** — a Backups view in the tenant console showing last
  successful backup / continuous-archiving health, an on-demand "Back up now"
  action (an `on-demand Backup` CR), and a gated + audited restore/PITR request
  flow. Restore is destructive, so it stays an operator-approved action behind the
  entitlement, never a self-serve button without confirmation.

Design constraints to preserve so this stays cheap later: keep `serverName` a
stable per-tenant input (never derived from anything that changes), keep the
ObjectStore/credentials per-tenant-namespace-scoped (no shared keys), and keep the
ScheduledBackup schedule + retention as values, not hardcodes. No control-plane
code is written here; this section is the forward contract.
