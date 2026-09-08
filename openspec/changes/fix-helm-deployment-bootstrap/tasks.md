# Tasks: Fix Helm Deployment Bootstrap

## Service Health Audit (Current State)

| Service | Pods | Status | Health |
|---------|------|--------|--------|
| cnpg-staging | 3/3 | Running | Healthy |
| serviceradar-nats | 1/1 | Running | Healthy |
| serviceradar-datasvc | 1/1 | Running | Healthy |
| serviceradar-agent | 1/1 | Running | Healthy |
| serviceradar-mapper | 1/1 | Running | Healthy |
| serviceradar-zen | 1/1 | Running | Healthy |
| serviceradar-flowgger | 1/1 | Running | Healthy |
| serviceradar-trapd | 1/1 | Running | Healthy |
| serviceradar-otel | 1/1 | Running | Healthy |
| serviceradar-faker | 1/1 | Running | Healthy |
| serviceradar-snmp-checker | 1/1 | Running | Healthy |
| serviceradar-tools | 1/1 | Running | Healthy |
| serviceradar-rperf-client | 1/1 | Running | Healthy |
| spire-server | 1/2 | Running | **UNHEALTHY** - CNPG TLS CA trust |
| spire-agent | 6/6 | Running | Degraded (depends on spire-server) |
| serviceradar-db-event-writer | 1/1 | Running | **UNHEALTHY** - CNPG TLS CA trust |
| serviceradar-core | 1/1 | Running | **UNHEALTHY** - Oban tables missing |
| serviceradar-web-ng | 0/2 | CrashLoopBackOff | **UNHEALTHY** - Horde naming + SSL |

---

## Phase 1: Fix CNPG TLS CA Trust

### 1.1 SPIRE Server CNPG Connection

- [ ] **1.1.1 Update spire-server ConfigMap with CA path**
  - File: `helm/serviceradar/templates/spire-server.yaml`
  - Add `root_ca = "/etc/serviceradar/cnpg/ca.crt"` to datastore config

- [ ] **1.1.2 Mount cnpg-ca secret into spire-server**
  - File: `helm/serviceradar/templates/spire-server.yaml`
  - Add volume mount for `{{ .Values.cnpg.clusterName }}-ca` secret at `/etc/serviceradar/cnpg`

- [ ] **1.1.3 Verify spire-server connects to CNPG**
  - Both containers should be Running (2/2)
  - No x509 errors in logs

### 1.2 db-event-writer CNPG Connection

- [ ] **1.2.1 Mount cnpg-ca secret into db-event-writer**
  - File: `helm/serviceradar/templates/db-event-writer.yaml`
  - Add volume for cnpg-ca secret
  - Add volume mount at `/etc/serviceradar/cnpg`

- [ ] **1.2.2 Update db-event-writer config to use CA**
  - File: `helm/serviceradar/templates/db-event-writer-config.yaml`
  - Add `sslRootCert` field pointing to `/etc/serviceradar/cnpg/ca.crt`

- [ ] **1.2.3 Verify db-event-writer connects to CNPG**
  - No x509 errors in logs
  - Successfully inserts batch messages

---

## Phase 2: Fix Oban Schema Migration

### 2.1 Analyze current state

- [ ] **2.1.1 Check where Oban tables currently exist**
  - Run: `SELECT schemaname, tablename FROM pg_tables WHERE tablename LIKE 'oban%';`
  - Expected: tables in `public` schema (current bug)
  - Target: tables in `platform` schema

### 2.2 Fix migration to use search_path schema

- [ ] **2.2.1 Remove prefix from Oban.Migrations.up() call**
  - File: `elixir/serviceradar_core/priv/repo/migrations/20260117090000_rebuild_schema.exs`
  - Change: `Oban.Migrations.up(prefix: oban_prefix)` → `Oban.Migrations.up()`
  - Already done in previous session

- [ ] **2.2.2 Create SQL script to move Oban tables to platform schema**
  - Drop tables from public schema
  - Create tables in platform schema
  - Or: Use ALTER TABLE SET SCHEMA to move them

- [ ] **2.2.3 Delete migration record to allow re-run**
  - Run: `DELETE FROM platform.schema_migrations WHERE version = 20260117090000;`
  - OR: Create new migration version

### 2.3 Alternative: Fresh database reset

- [ ] **2.3.1 Document the nuclear option**
  - Delete CNPG cluster
  - Delete PVCs
  - Re-deploy from scratch with corrected migration

---

## Phase 3: Fix web-ng Horde Naming

### 3.1 Apply ProcessSupervisor fix

- [ ] **3.1.1 Check if web-ng uses same ProcessRegistry module**
  - Search for Horde.DynamicSupervisor usage in web-ng
  - Identify naming conflict source

- [ ] **3.1.2 Update ProcessRegistry module (if applicable)**
  - Change `@supervisor_name ServiceRadar.ProcessRegistry.Supervisor`
  - To: `@supervisor_name ServiceRadar.ProcessSupervisor`

- [ ] **3.1.3 Build and push new web-ng image**
  - Run: `bazel run //docker/images:push_web_ng_image_amd64`

- [ ] **3.1.4 Rollout web-ng deployment**
  - Run: `kubectl rollout restart deployment/serviceradar-web-ng -n demo-staging`

- [ ] **3.1.5 Verify web-ng pod reaches Ready state**
  - Pod should be 1/1 Running
  - No Horde.DynamicSupervisorImpl errors in logs

---

## Phase 4: Validation

### 4.1 Helm upgrade and verify

- [ ] **4.1.1 Apply Helm changes**
  - Run: `helm upgrade serviceradar ./helm/serviceradar -n demo-staging`

- [ ] **4.1.2 Wait for pods to stabilize**
  - All pods should reach Running state
  - No CrashLoopBackOff

- [ ] **4.1.3 Check service logs for errors**
  - `kubectl logs -n demo-staging -l app=serviceradar-core --tail=50`
  - `kubectl logs -n demo-staging -l app=serviceradar-web-ng --tail=50`
  - `kubectl logs -n demo-staging spire-server-0 -c spire-server --tail=50`
  - `kubectl logs -n demo-staging -l app=serviceradar-db-event-writer --tail=50`

### 4.2 Fresh install test

- [ ] **4.2.1 Delete demo-staging namespace**
  - Run: `kubectl delete namespace demo-staging`
  - Wait for all resources to be cleaned up

- [ ] **4.2.2 Delete CNPG PVCs**
  - Ensure no leftover PVCs from previous CNPG cluster

- [ ] **4.2.3 Fresh helm install**
  - Run: `helm install serviceradar ./helm/serviceradar -n demo-staging --create-namespace`

- [ ] **4.2.4 Verify all pods healthy within 5 minutes**
  - All pods should reach Running state
  - No manual intervention required

---

## Verification Checklist

- [ ] CNPG cluster healthy (3/3 pods)
- [ ] SPIRE server healthy (2/2 containers)
- [ ] SPIRE agents healthy (all pods Running)
- [ ] db-event-writer no TLS errors
- [ ] core-elx no Oban errors
- [ ] web-ng Running (1/1)
- [ ] All pods in Running state
- [ ] No CrashLoopBackOff
- [ ] Fresh helm install works without manual intervention

---

## Files to Modify

1. `helm/serviceradar/templates/spire-server.yaml` - Add CNPG CA mount
2. `helm/serviceradar/templates/db-event-writer.yaml` - Add CNPG CA mount
3. `helm/serviceradar/templates/db-event-writer-config.yaml` - Add sslRootCert
4. `elixir/serviceradar_core/priv/repo/migrations/20260117090000_rebuild_schema.exs` - Remove Oban prefix (already done)
5. `web-ng` Horde naming fix (if applicable)
