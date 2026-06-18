## 1. Cluster-bootstrap: install the barman-cloud plugin (operator-scoped, separate PR)
- [ ] 1.1 Confirm cert-manager is installed and healthy in the target cluster (plugin hard prerequisite).
- [ ] 1.2 In the `serviceradar-control` repo `k8s/platform/cnpg/`, add the barman-cloud plugin install (pinned release ≥ v0.11.0, CNPG ≥ 1.26 compatible) into `cnpg-system` — pinned `manifest.yaml` or the `cnpg/plugin-barman-cloud` Helm chart, NOT the per-tenant serviceradar chart.
- [ ] 1.3 Pin the plugin image/digest (do not track `latest`); ensure cert-manager is a sync-wave predecessor.
- [ ] 1.4 Verify `kubectl get crd objectstores.barmancloud.cnpg.io`, `kubectl -n cnpg-system get deploy barman-cloud` Ready 1/1, and the plugin Certificate is issued.
- [ ] 1.5 Confirm the ObjectStore CRD is NOT vendored into `helm/serviceradar/crds/` (cluster-scoped, plugin-owned).

## 2. Deploy SeaweedFS on Longhorn (the in-cluster S3 target)
- [ ] 2.1 Create namespace `serviceradar-backups`.
- [ ] 2.2 Deploy SeaweedFS (master + volume + filer + standalone s3, discrete components, replicas 1 each) with the official chart; back `volume`/`filer`/`master` data with `storageClass: longhorn`; size per the capacity plan.
- [ ] 2.3 Create the `seaweedfs-s3-config` Secret (admin identity + per-tenant scoped identities; `actions: Read:/Write:/List:/Tagging:<bucket>`); never commit keys to git.
- [ ] 2.4 Pre-create the bucket(s) (`createBuckets`) — demo `serviceradar-demo`, one per tenant for SaaS; use DNS-label-safe lowercase names.
- [ ] 2.5 Verify the S3 endpoint `http://seaweedfs-s3.serviceradar-backups.svc.cluster.local:8333` is reachable in-cluster (path-style list/put).
- [ ] 2.6 (Recommended) Configure a Longhorn off-cluster BackupTarget for the SeaweedFS PVC (backup-of-the-backup, 3-2-1).

## 3. Chart templating + values (gated, off by default)
- [ ] 3.1 Add a `cnpg.backup` block to `values.yaml` (`enabled: false`, objectStore name/destinationPath/bucket/endpointURL/credentialsSecret, wal/data compression, retention, schedule, serverName, target) and a `seaweedfs` block (off by default) — secure defaults.
- [ ] 3.2 NEW `templates/cnpg-backup.yaml`: render `ObjectStore` (`barmancloud.cnpg.io/v1`, `serverName: ""`, `s3Credentials` referencing the tenant secret keys `ACCESS_KEY_ID`/`ACCESS_SECRET_KEY`, `retentionPolicy`) + `ScheduledBackup` (`method: plugin`, `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`), gated on `cnpg.backup.enabled`, with `helm.sh/resource-policy: keep`.
- [ ] 3.3 EDIT `templates/cnpg-cluster.yaml`: add gated `spec.plugins[]` (`name: barman-cloud.cloudnative-pg.io`, `isWALArchiver: true`, `parameters.barmanObjectName`, `parameters.serverName`) under `spec`, conditional on `cnpg.backup.enabled`; keep the existing `max_slot_wal_keep_size` cap (complementary, not conflicting).
- [ ] 3.4 (Optional) NEW `templates/seaweedfs.yaml` for the per-tenant SaaS model OR ship SeaweedFS as a separate ArgoCD app for the shared-store demo model — pick one and document it.
- [ ] 3.5 EDIT NetworkPolicy templates (`network-policy.yaml` / `cnpg-application-network-policy.yaml`) to permit CNPG instance pods (label `cnpg.io/cluster` Exists) → SeaweedFS S3 `:8333`; keep intra-SeaweedFS traffic open.
- [ ] 3.6 `helm template` for default values (backups off → unchanged render) and for demo/backup-enabled values; assert ObjectStore + plugins + ScheduledBackup render correctly.

## 4. Wire + verify on the demo cluster (live ops)
- [ ] 4.1 Wait until `demo/cnpg` is `Healthy` (3/3 Ready) — do NOT enable a required WAL archiver mid-rebuild.
- [ ] 4.2 Create `cnpg-backup-s3-creds` Secret in `demo` (keys `ACCESS_KEY_ID`/`ACCESS_SECRET_KEY`, demo-scoped identity).
- [ ] 4.3 Apply the `ObjectStore` (`destinationPath: s3://serviceradar-demo/`, `endpointURL` to SeaweedFS); add checksum env overrides if uploads error.
- [ ] 4.4 Add `spec.plugins[]` WAL archiver to `demo/cnpg` and confirm `ContinuousArchiving` condition goes healthy and WAL objects appear in the bucket.
- [ ] 4.5 Apply the `ScheduledBackup` (`immediate: true`) and confirm a `Backup` completes (`kubectl get backup -n demo`, base backup object in the bucket).
- [ ] 4.6 Run a **test PITR**: bootstrap a throwaway recovery Cluster (on `longhorn`) from the ObjectStore with a `recoveryTarget.targetTime`, verify it reaches a healthy primary and data is sane; retire it.

## 5. SaaS per-tenant generalization
- [ ] 5.1 Document the onboarding steps: create bucket `sr-backups-<id>`, scoped identity, tenant-namespace Secret, render chart with `cnpg.backup.enabled`, `serverName=<id>-<clusterName>`, `destinationPath=s3://sr-backups-<id>/`.
- [ ] 5.2 Document offboarding: delete tenant namespace, then `delete bucket` + remove the SeaweedFS identity (atomic, no prefix walking).
- [ ] 5.3 Stagger ScheduledBackup cron per tenant (hash on serverName); set `target: prefer-standby`.
- [ ] 5.4 Define retention tiers (free `7d` weekly / standard `30d` nightly / premium `90d`) mapped to per-tenant values; ensure `retentionPolicy` ≥ 2× base-backup interval.
- [ ] 5.5 Broaden the NetworkPolicy for all tenant namespaces via a shared label rather than enumerating each.

## 6. Docs, observability, runbook
- [ ] 6.1 Update `helm/serviceradar/README.md`: backups are opt-in (`cnpg.backup.enabled` + SeaweedFS prerequisite), the secret-key contract, the recovery path (`externalClusters[].plugin` + `barmanObjectName`/`serverName`).
- [ ] 6.2 Add alerts: ScheduledBackup not completed in 26h; `ContinuousArchiving` condition != healthy; SeaweedFS Longhorn volume > 75%; per-bucket object count flatlining (archiving silently stopped).
- [ ] 6.3 Write the DR runbook (single-tenant DB loss; full control-plane loss; SeaweedFS/Longhorn loss; standing restore drill).
- [ ] 6.4 Capacity-plan the shared SeaweedFS volume PVC for N tenants (Σ per-tenant footprint × Longhorn replica factor + slack); alert Longhorn aggregate at 75%.

## 7. Validation
- [ ] 7.1 `helm template` default (backups off) and demo (backups on) render cleanly.
- [ ] 7.2 `openspec validate add-cnpg-barman-backups --strict` passes.
