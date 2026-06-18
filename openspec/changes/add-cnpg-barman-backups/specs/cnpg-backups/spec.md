# cnpg-backups

## ADDED Requirements

### Requirement: Continuous WAL archiving to a self-hosted object store
The system SHALL continuously archive Postgres WAL from each CNPG cluster to a
self-hosted, in-cluster S3-compatible object store (SeaweedFS backed by a Longhorn
PVC) using the barman-cloud plugin (`barman-cloud.cloudnative-pg.io`) with
`isWALArchiver: true`. The object store MUST reside in a different fault domain
than the cluster's Postgres data volume, and no paid cloud object storage SHALL be
required. WAL archiving and the local `max_slot_wal_keep_size` cap MUST remain
complementary controls (archiving offloads WAL to the store; the cap bounds local
disk).

#### Scenario: WAL segments are shipped off the data volume
- **WHEN** a CNPG cluster has backups enabled and a WAL segment is completed on the primary
- **THEN** the barman-cloud WAL-archiver sidecar uploads that segment to the configured object store
- **AND** the cluster's `ContinuousArchiving` condition reports healthy

#### Scenario: Archiving does not write to a cluster's own data disk
- **WHEN** WAL archiving is configured for a cluster whose data volume is on local-path storage
- **THEN** archived WAL is written to the SeaweedFS object store on Longhorn, not to the cluster's data volume

### Requirement: Scheduled base backups with retention
The system SHALL take recurring base backups via a `ScheduledBackup` using
`method: plugin` and `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`,
and SHALL enforce a retention policy configured on the `ObjectStore`
(`spec.retentionPolicy`, form `XXu` with `u` in `{d,w,m}`) that expires base
backups and their no-longer-needed WAL beyond the window. Retention SHALL be at
least twice the base-backup interval so a fallback base backup always exists in
the window.

#### Scenario: A scheduled base backup completes and lands in the object store
- **WHEN** the configured backup schedule fires (or an immediate ScheduledBackup is created)
- **THEN** a `Backup` resource reaches `completed`
- **AND** a base backup object appears in the cluster's bucket

#### Scenario: Out-of-window base backups are expired
- **WHEN** a base backup is older than the configured `retentionPolicy` window
- **THEN** that base backup and its no-longer-required WAL are removed from the object store

### Requirement: Point-in-time recovery into a new cluster
The system SHALL support point-in-time recovery (PITR) by bootstrapping a NEW
CNPG cluster from an `ObjectStore` via `bootstrap.recovery` and an
`externalClusters[].plugin` reference whose `serverName` equals the source
cluster's `serverName`. CNPG SHALL NOT restore in place; recovery MUST target a
new cluster that is then cut over to. A recovery target time (to the second)
SHALL be honored when supplied.

#### Scenario: Restore to a specific timestamp
- **WHEN** an operator creates a recovery cluster with `recoveryTarget.targetTime` set to a time within the retention window
- **AND** the external cluster's `serverName` matches the original
- **THEN** the recovery cluster reaches a healthy primary recovered to that timestamp

#### Scenario: Recovered cluster gets a fresh forward serverName
- **WHEN** a recovery cluster is promoted and begins archiving its own WAL
- **THEN** it uses a fresh `serverName` so its new WAL does not collide with the source backup series

### Requirement: Replica rebuild from the WAL archive
The system SHALL allow a new or re-cloning CNPG replica to fetch missing WAL
segments from the object store via the plugin-injected `restore_command`, so that
a replica which falls behind does not fail with `requested WAL segment has already
been removed` when the primary has recycled that segment locally.

#### Scenario: A lagging replica recovers a recycled segment from the archive
- **WHEN** a replica needs a WAL segment that the primary has already recycled locally
- **AND** that segment was archived to the object store after archiving was enabled
- **THEN** the replica fetches the segment from the object store and continues replication instead of failing

### Requirement: Per-tenant backup isolation
For the instance-per-tenant SaaS model, the system SHALL isolate each tenant's
backups in a dedicated bucket (`sr-backups-<tenantId>`) with a dedicated,
whole-bucket-scoped S3 identity, and SHALL store each tenant's S3 credentials in a
Secret in that tenant's own namespace. A single shared S3 key spanning multiple
tenants via path prefixes MUST NOT be used. Each tenant's `serverName` SHALL be
stable for the life of the tenant; the `ObjectStore` `serverName` field MUST be
left empty (per-cluster identity is set via the Cluster plugin parameter).

#### Scenario: A leaked tenant key cannot read another tenant's backups
- **WHEN** one tenant's scoped S3 access key is compromised
- **THEN** it grants access only to that tenant's bucket and no other tenant's backup data

#### Scenario: Tenant offboarding removes only that tenant's backups
- **WHEN** a tenant is offboarded
- **THEN** deleting that tenant's bucket and S3 identity removes its backups atomically without touching other tenants' data

### Requirement: Backups are opt-in and secure by default
Backups SHALL be disabled by default in the Helm chart (`cnpg.backup.enabled:
false`); installs that do not enable backups SHALL render unchanged and SHALL NOT
require SeaweedFS or the barman-cloud plugin. The barman-cloud plugin and its
cluster-scoped `ObjectStore` CRD SHALL be installed by the cluster-bootstrap layer
in `cnpg-system`, and MUST NOT be vendored into the per-tenant chart's `crds/`.
Only CNPG instance pods (which run the WAL-archiver sidecar) SHALL be permitted by
NetworkPolicy to reach the object store's S3 port.

#### Scenario: A chart install without backups is unaffected
- **WHEN** the chart is rendered with `cnpg.backup.enabled: false`
- **THEN** no `ObjectStore`, `ScheduledBackup`, or `spec.plugins` WAL-archiver block is produced
- **AND** the install does not require the barman-cloud plugin or SeaweedFS to be present

#### Scenario: Only CNPG pods can reach the S3 endpoint
- **WHEN** a non-CNPG pod attempts to connect to the SeaweedFS S3 port
- **THEN** the NetworkPolicy denies the connection
- **AND** CNPG instance pods are permitted to reach the S3 port for archiving and backups
