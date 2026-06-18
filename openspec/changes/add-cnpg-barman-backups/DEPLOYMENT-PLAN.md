# Deployment Plan — Self-hosted CNPG backups (SeaweedFS + barman-cloud) on the demo cluster

Concrete, ordered, copy-pasteable steps to stand up self-hosted CNPG backups on
the live `demo` namespace as the proving ground. **No paid cloud object storage.**

Legend:
- **[LIVE-OPS]** = a command the operator (you) runs against the live cluster.
- **[CHART]** = a code/templating change committed to this repo (lands via ArgoCD).
- **[BOOTSTRAP]** = lives in the cluster-bootstrap repo (`serviceradar-control`),
  NOT this chart.

Verified live facts (read-only) at authoring time:
- CNPG operator `ghcr.io/cloudnative-pg/cloudnative-pg:1.27.1` in `cnpg-system`.
- No `objectstores.barmancloud.cnpg.io` CRD → plugin not installed.
- cert-manager installed and healthy (plugin prerequisite met).
- StorageClass `longhorn` (`driver.longhorn.io`, `numberOfReplicas: 2`).
- `demo/cnpg`: 3 instances on `local-path-cnpg`, **currently 2/3 Ready,
  "Creating a new replica"** — DO NOT enable a required WAL archiver until 3/3.

Replace placeholder keys (`DEMO_AK`/`DEMO_SK`/`ADMIN_AK`/`ADMIN_SK`) with values
from `openssl rand -hex 16` (access) / `openssl rand -hex 24` (secret). Never
commit keys.

---

## Step 0 — Preflight (LIVE-OPS, read-only)

```bash
kubectl get deploy -n cnpg-system cnpg-operator-cloudnative-pg \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # expect :1.27.1
kubectl get crd objectstores.barmancloud.cnpg.io 2>&1 || echo "plugin not installed (expected)"
kubectl get sc longhorn -o jsonpath='{.provisioner} replicas={.parameters.numberOfReplicas}{"\n"}'
kubectl -n cert-manager get deploy                               # all Ready
kubectl get cluster cnpg -n demo                                 # wait for 3/3 Ready before Step 6
```

---

## Step 1 — Install the barman-cloud plugin into cnpg-system (BOOTSTRAP; one-time, cluster-wide)

Pin the version; do not track `latest`. Plugin ≥ v0.11.0 requires CNPG ≥ 1.26
(we are on 1.27.1). This creates the `objectstores.barmancloud.cnpg.io` CRD, the
`barman-cloud` Deployment/Service in `cnpg-system`, RBAC, and a cert-manager
Certificate for plugin↔operator mTLS.

```bash
# LIVE-OPS form (then commit the pinned manifest into serviceradar-control k8s/platform/cnpg/):
kubectl apply -f \
  https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.11.0/manifest.yaml

kubectl -n cnpg-system rollout status deploy barman-cloud
kubectl get crd objectstores.barmancloud.cnpg.io
kubectl -n cnpg-system get certificate
```

> Do NOT vendor this CRD into `helm/serviceradar/crds/`. It is cluster-scoped,
> plugin-owned, and shared by every tenant cluster.

---

## Step 2 — Deploy SeaweedFS on Longhorn (LIVE-OPS; shared store)

Dedicated namespace, 4 discrete components, Longhorn-backed PVCs.

```bash
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo update
kubectl create namespace serviceradar-backups
```

`seaweedfs-values.yaml` (demo baseline; SaaS comments inline):

```yaml
master:
  enabled: true
  replicas: 1
  volumeSizeLimitMB: 30000        # fewer, larger volume files for big backup objects
  data: { type: persistentVolumeClaim, storageClass: longhorn, size: 4Gi }
  resources: { requests: { cpu: "50m", memory: "128Mi" }, limits: { cpu: "500m", memory: "512Mi" } }
volume:
  enabled: true
  replicas: 1
  dataDirs:
    - name: data
      type: persistentVolumeClaim
      storageClass: longhorn
      size: 100Gi                 # demo. SaaS/200GB-DB: 750Gi–1Ti, grow via Longhorn expansion
      maxVolumes: 0
  resources: { requests: { cpu: "100m", memory: "256Mi" }, limits: { cpu: "1", memory: "1Gi" } }
filer:
  enabled: true
  replicas: 1
  enablePVC: true
  storage: 8Gi
  storageClass: longhorn
  s3: { enabled: false }          # use the standalone s3 component below
  resources: { requests: { cpu: "100m", memory: "256Mi" }, limits: { cpu: "1", memory: "1Gi" } }
s3:
  enabled: true
  port: 8333
  enableAuth: true
  existingConfigSecret: seaweedfs-s3-config
  createBuckets:
    - name: serviceradar-demo     # demo. SaaS: one bucket per tenant (sr-backups-<id>)
  resources: { requests: { cpu: "100m", memory: "256Mi" }, limits: { cpu: "1", memory: "1Gi" } }
global:
  seaweedfs:
    enableSecurity: false         # rely on NetworkPolicy intra-cluster
    monitoring: { enabled: false }
```

S3 identities Secret (gateway side) — create BEFORE the helm install:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: seaweedfs-s3-config
  namespace: serviceradar-backups
type: Opaque
stringData:
  seaweedfs_s3_config: |
    {
      "identities": [
        { "name": "admin",
          "credentials": [{ "accessKey": "ADMIN_AK", "secretKey": "ADMIN_SK" }],
          "actions": ["Admin", "Read", "Write"] },
        { "name": "cnpg-demo",
          "credentials": [{ "accessKey": "DEMO_AK", "secretKey": "DEMO_SK" }],
          "actions": ["Read:serviceradar-demo","Write:serviceradar-demo","List:serviceradar-demo","Tagging:serviceradar-demo"] }
      ]
    }
EOF

helm upgrade --install seaweedfs seaweedfs/seaweedfs \
  -n serviceradar-backups -f seaweedfs-values.yaml

kubectl -n serviceradar-backups rollout status deploy/sts --timeout=5m 2>/dev/null || \
  kubectl -n serviceradar-backups get pods
kubectl -n serviceradar-backups get svc seaweedfs-s3
```

Endpoint pods will use (path-style):
`http://seaweedfs-s3.serviceradar-backups.svc.cluster.local:8333` → bucket
`serviceradar-demo` → `destinationPath: s3://serviceradar-demo/`.

---

## Step 3 — NetworkPolicy: only CNPG pods reach S3:8333 (CHART or LIVE-OPS)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: seaweedfs-s3-allow-cnpg
  namespace: serviceradar-backups
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: seaweedfs, app.kubernetes.io/component: s3 }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: demo } }
          podSelector: { matchExpressions: [ { key: cnpg.io/cluster, operator: Exists } ] }
      ports: [ { protocol: TCP, port: 8333 } ]
```

Keep a separate policy allowing intra-SeaweedFS traffic (master↔volume↔filer↔s3
on 9333/19333/8888/18888/8080). For SaaS, broaden the `namespaceSelector` to a
shared tenant label instead of enumerating namespaces.

---

## Step 4 — CNPG-side S3 credentials Secret (LIVE-OPS, in `demo`)

The barman plugin reads creds from keys `ACCESS_KEY_ID` / `ACCESS_SECRET_KEY`.

```bash
kubectl -n demo create secret generic cnpg-backup-s3-creds \
  --from-literal=ACCESS_KEY_ID=DEMO_AK \
  --from-literal=ACCESS_SECRET_KEY=DEMO_SK
```

---

## Step 5 — ObjectStore CR (CHART: templates/cnpg-backup.yaml; or LIVE-OPS to validate first)

`serverName` MUST be empty here; per-cluster identity is set on the Cluster plugin.

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: serviceradar-demo-store
  namespace: demo
spec:
  retentionPolicy: "30d"
  configuration:
    destinationPath: s3://serviceradar-demo/
    endpointURL: http://seaweedfs-s3.serviceradar-backups.svc.cluster.local:8333
    s3Credentials:
      accessKeyId:     { name: cnpg-backup-s3-creds, key: ACCESS_KEY_ID }
      secretAccessKey: { name: cnpg-backup-s3-creds, key: ACCESS_SECRET_KEY }
    wal:  { compression: gzip, maxParallel: 4 }
    data: { compression: gzip, jobs: 2 }
  # If basebackup/WAL uploads error against SeaweedFS (boto3 checksums), add:
  # instanceSidecarConfiguration:
  #   env:
  #     - { name: AWS_REQUEST_CHECKSUM_CALCULATION, value: when_required }
  #     - { name: AWS_RESPONSE_CHECKSUM_VALIDATION, value: when_required }
```

```bash
kubectl apply -f objectstore-demo.yaml
kubectl -n demo get objectstore serviceradar-demo-store
```

---

## Step 6 — Enable WAL archiving on demo/cnpg (CHART: cnpg-cluster.yaml spec.plugins)

> GATE: only when `kubectl get cluster cnpg -n demo` shows **3/3 Ready /
> Healthy**. A failing required WAL archiver retains WAL locally (the 2026-06-17
> shape; bounded by `max_slot_wal_keep_size: 250GB` but still alarms).

The chart renders this gated on `cnpg.backup.enabled`. To validate live first:

```bash
kubectl patch cluster cnpg -n demo --type=merge -p '{
  "spec": { "plugins": [ {
    "name": "barman-cloud.cloudnative-pg.io",
    "isWALArchiver": true,
    "parameters": { "barmanObjectName": "serviceradar-demo-store", "serverName": "demo-cnpg" }
  } ] }
}'
```

Verify archiving is active:

```bash
kubectl get cluster cnpg -n demo -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
# expect ContinuousArchiving=True
kubectl -n demo logs <primary-pod> -c plugin-barman-cloud --tail=50 2>/dev/null | grep -i archive
# WAL objects should appear under s3://serviceradar-demo/ (list via the admin identity)
```

---

## Step 7 — ScheduledBackup + first base backup (CHART: cnpg-backup.yaml; LIVE-OPS to verify)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: serviceradar-demo-daily
  namespace: demo
spec:
  schedule: "0 0 3 * * *"          # 6-field cron incl. seconds → 03:00 daily
  immediate: true
  backupOwnerReference: self
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
  cluster: { name: cnpg }
  target: prefer-standby           # offload base-backup I/O to a replica
```

```bash
kubectl apply -f scheduledbackup-demo.yaml
kubectl -n demo get backup -w        # wait for phase=completed
# confirm a base backup object exists under s3://serviceradar-demo/
```

---

## Step 8 — Test PITR (LIVE-OPS; a backup never restored is not a backup)

Bootstrap a THROWAWAY recovery cluster on `longhorn` (CNPG never restores in
place). The external cluster `serverName` MUST equal the source (`demo-cnpg`).

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: cnpg-restore-test, namespace: demo }
spec:
  instances: 1
  storage: { size: 50Gi, storageClass: longhorn }
  bootstrap:
    recovery:
      source: demo-origin
      recoveryTarget: { targetTime: "2026-06-18 12:00:00.000000+00" }   # within retention
  externalClusters:
    - name: demo-origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: serviceradar-demo-store, serverName: demo-cnpg }
```

```bash
kubectl apply -f restore-test.yaml
kubectl get cluster cnpg-restore-test -n demo -w    # reaches healthy primary
# sanity-check row counts / latest data, then tear down:
kubectl delete cluster cnpg-restore-test -n demo
```

---

## Step 9 — Promote to chart + values (CHART)

Move the live-validated CRs into the chart so ArgoCD owns them:
- `helm/serviceradar/values.yaml`: add `cnpg.backup` + `seaweedfs` blocks, both
  **off by default**.
- `helm/serviceradar/values-demo.yaml`: opt in (`cnpg.backup.enabled: true`,
  `objectStore.bucket: serviceradar-demo`, retention/schedule); SeaweedFS as a
  separate ArgoCD app in `serviceradar-backups` (cleaner lifecycle) OR a gated
  `templates/seaweedfs.yaml` for the per-tenant SaaS model.
- `helm/serviceradar/templates/cnpg-cluster.yaml`: gated `spec.plugins[]`.
- `helm/serviceradar/templates/cnpg-backup.yaml`: ObjectStore + ScheduledBackup.
- NetworkPolicy templates: CNPG → SeaweedFS:8333.
- `k8s/argocd/applications/demo-prod.yaml`: confirm CNPG `ignoreDifferences`
  still covers only `/spec/instances` + `/spec/storage/size` (do NOT add
  `/spec/plugins` — it must reconcile).

---

## SaaS generalization (per tenant)

One **shared** SeaweedFS, **one bucket + one scoped identity per tenant**:
1. Create bucket `sr-backups-<id>` + a SeaweedFS identity scoped to it.
2. Write `cnpg-backup-s3-creds` (keys `ACCESS_KEY_ID`/`ACCESS_SECRET_KEY`) into
   the tenant namespace (sealed-secret / external-secret, never plaintext).
3. Render the chart for the tenant: `cnpg.backup.enabled=true`,
   `serverName=<id>-<clusterName>` (STABLE forever),
   `destinationPath=s3://sr-backups-<id>/`.
4. Stagger the ScheduledBackup cron (hash on serverName) to avoid a 02:00 stampede.
5. Offboard: delete the tenant namespace, then `delete bucket sr-backups-<id>` +
   remove the SeaweedFS identity (atomic).

---

## Operational guardrails / alerts (LIVE-OPS / monitoring)

- `ScheduledBackup` not completed in 26h.
- `ContinuousArchiving` condition != True on any cluster.
- SeaweedFS Longhorn volume > 75% (and Longhorn aggregate node disk > 75%).
- Per-bucket object count flatlining (archiving silently stopped).
- Configure a Longhorn off-cluster BackupTarget for the SeaweedFS PVC — the
  backup-of-the-backup (3-2-1). Self-hosted still needs host/geo separation.
- Standing weekly restore drill: restore one rotating tenant to a known
  timestamp in a throwaway namespace; assert success.
