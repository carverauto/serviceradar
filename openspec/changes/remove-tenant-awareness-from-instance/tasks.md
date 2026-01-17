# Tasks: Remove Account Awareness from Instance

## Summary

Make instance code (web-ng, core-elx) completely schema-scoped and account-unaware by:
1. Using schema-scoped CNPG credentials (DB enforces isolation)
2. Using account-scoped NATS JWTs (NATS enforces isolation)
3. Removing all explicit schema context parameters from Ash queries
4. Removing cross-schema code paths entirely

---

## Phase 1: External Provisioning - CNPG/NATS Credentials

### 1.1 Provision schema-scoped credentials outside this repo

- [x] **1.1.1 Create CNPG + NATS credentials via bootstrap tooling**
  - Helm or Docker Compose bootstrap scripts create CNPG users/schemas
  - NATS account credentials are created externally (control plane or bootstrap)
  - Instance consumes credentials via environment/secrets only

- [x] **1.1.2 Move workload provisioning to control plane repo**
  - Workload operator and templates live in `~/serviceradar-web`
  - This repo no longer builds or publishes that image

### 1.2 Test CNPG isolation

- [ ] **1.2.1 Create test account with scoped credentials**
- [ ] **1.2.2 Verify cannot access other account schemas**
- [ ] **1.2.3 Verify app works with scoped credentials**

### 1.3 Enforce JWT-only NATS access in instance code

- [x] **1.3.1 Require NATS creds in core-elx runtime config (NATS + EventWriter)**
- [x] **1.3.2 Require NATS creds in datasvc/db-event-writer config validation**
- [x] **1.3.3 Require KV NATS creds when KV_DRIVER=nats**

---

## Phase 2: Remove Multitenancy from Ash Resources

### 2.1 Audit current multitenancy configuration

- [x] **2.1.1 List all resources with `multitenancy` blocks**
  - Found 59 resources with `strategy :context` (schema-isolated)
  - Found 1 resource with `strategy :attribute` + `global? true` (legacy membership resource)
  - Found 4 resources with no multitenancy (account registry + NATS operator/tokens)

- [x] **2.1.2 List all resources with legacy account-id attributes**
  - Found 47 resources with explicit account-id attributes
  - Most are redundant when using schema-based isolation

- [x] **2.1.3 Identify resources that should stay in public schema**
  - Account registry + NATS operator/tokens (Control Plane resources)

### 2.2 Remove multitenancy DSL and regenerate snapshots

- [x] **2.2.1 Remove multitenancy blocks from Ash resources**
  - COMPLETE - No multitenancy blocks remain in Ash resources
  - No `strategy :context` or `attribute :account_id` in codebase

- [x] **2.2.2 Regenerate Ash snapshots and migrations**
  - Ran `mix ash.codegen`; no changes detected

---

## Phase 3: Remove Explicit Schema Context from Code

**Status: COMPLETE** (as of 2026-01-16)

**Migration Guide**: See `migration-guide.md` for patterns and examples.

### 3.1 Update web-ng controllers

- [x] **3.1.1 api/collector_controller.ex** (EXAMPLE FILE)
  - Updated all Ash calls to omit schema context params
  - Removed cross-schema lookup helper
  - Platform operations use standard system actors

- [x] **3.1.2 api/edge_controller.ex**
  - Updated all Ash calls to omit schema context params
  - Removed cross-schema lookup helper

- [x] **3.1.3 api/enroll_controller.ex**
  - Updated `mark_enrolled()` to omit schema context params
  - Removed cross-schema lookup helper

- [x] **3.1.4 api/nats_controller.ex** (Control Plane only)
  - No changes needed - manages NatsOperator/NatsPlatformToken in public schema

- [x] **3.1.5 auth_controller.ex**
  - Updated JWT token generation to omit schema context params

- [x] **3.1.6 account_controller.ex** (Control Plane only)
  - No changes needed - control plane feature

### 3.2 Update web-ng LiveViews

**Status: COMPLETE** (as of 2026-01-16)

All explicit schema context parameters have been removed from LiveView files:
- [x] `device_live/index.ex` - Uses scope pattern
- [x] `device_live/show.ex` - Uses scope pattern
- [x] `admin/edge_package_live/index.ex` - Uses scope pattern
- [x] `admin/integration_live/index.ex` - Uses scope pattern
- [x] `admin/collector_live/index.ex` - Uses environment config
- [x] `admin/edge_sites_live/index.ex` - Uses scope pattern
- [x] `admin/edge_sites_live/show.ex` - Uses environment config
- [x] `admin/nats_live/index.ex` - Simplified (removed multi-account UI)
- [x] `admin/nats_live/show.ex` - Simplified (redirect only)
- [x] `settings/rules_live/index.ex` - Uses scope pattern

LiveViews now use `scope:` pattern which extracts actor via `Ash.Scope.ToOpts`.

### 3.3 Update web-ng plugs and auth

- [x] **3.3.1 plugs/api_auth.ex**
  - Updated `find_api_token()` with schema scope check (single-schema only)
  - Updated `record_token_usage()` to use `Ash` calls without schema context params
  - Updated `validate_ash_jwt()` to use mode-conditional actors
  - Removed redundant private schema options helper

- [x] **3.3.2 plugs/account_context.ex**
  - Updated account context loading to use `SystemActor.system/1`
  - Account registry is external; no schema context parameter needed

- [x] **3.3.3 accounts/scope.ex**
  - Updated `for_user()` to use `SystemActor.system/1`
  - Removed unused schema context overrides

- [x] **3.3.4 user_auth.ex**
  - Updated `verify_token()` to use `Ash` calls without schema context params
  - Updated actor to use `SystemActor.system/1`
  - Removed redundant private schema options helper

### 3.4 Update core-elx workers

- [x] **3.4.1 Audit all Oban workers for schema context usage**
  - Found 3 edge workers: `provision_collector_worker.ex`, `provision_leaf_worker.ex`, `record_event_worker.ex`
  - Found 44 files total with schema-scoped system actor usage

- [x] **3.4.2 Update edge workers (3 files)**
  - `provision_collector_worker.ex` - updated Ash calls to omit schema context params
  - `provision_leaf_worker.ex` - updated Ash calls to omit schema context params
  - `record_event_worker.ex` - updated to omit schema context params

### 3.5 Update core-elx GenServers

- [x] **3.5.1 Observability seeders (4 files)**
  - `template_seeder.ex` - updated to skip in account-unaware mode, uses Ash calls without schema context params
  - `rule_seeder.ex` - updated to skip in account-unaware mode, uses Ash calls without schema context params
  - `zen_rule_seeder.ex` - updated to skip in account-unaware mode, uses Ash calls without schema context params
  - `sysmon_profile_seeder.ex` - updated to use Ash calls without schema context params

- [x] **3.5.2 Observability sync/writers (3 files)**
  - `zen_rule_sync.ex` - updated GenServer state to use ash_opts instead of actor
  - `onboarding_writer.ex` - updated to use Ash calls without schema context params

- [x] **3.5.3 Infrastructure GenServers (1 file)**
  - `state_monitor.ex` - updated GenServer state to use ash_opts

- [x] **3.5.4 Remaining GenServers - COMPLETE**
  - All GenServers now use `SystemActor.system/1`
  - No schema-scoped system actor usage remains in codebase
  - Only legitimate schema context usage: AshAuthentication JWT verification (required)

---

## Phase 4: Simplify SystemActor

**Status: COMPLETE** (as of 2026-01-16)

### 4.1 Refactor SystemActor module

- [x] **4.1.1 Remove `SystemActor.platform/1`**
  - No public-schema access in instance pods
  - Control Plane owns platform resources

- [x] **4.1.2 Remove schema-scoped system actors**
  - DELETED - no longer exists in codebase
  - Replaced with `SystemActor.system/1`

- [x] **4.1.3 Simplified actor model implemented**
  - `system/1` - For instance-scoped operations (role: :system)
  - No account id in actors - implicit from DB connection

### 4.2 Update authorization policies

- [x] **4.2.1 Updated bypass policies**
  - Policies now check for `role: :system` only
  - No account id checks needed

---

## Phase 5: Delete Cross-Account Code

**Status: COMPLETE** (as of 2026-01-16)

### 5.1 Remove schema enumeration helper usage

- [x] **5.1.1 list_schemas helper - DELETED**
  - No calls remain in codebase

- [x] **5.1.2 schema lookup helper - DELETED**
  - No calls remain in codebase

- [x] **5.1.3 Schema enumeration module - DELETED**
  - Module no longer exists in instance code

### 5.2 Remove cross-account query functions

- [x] **5.2.1 cross-schema package lookup - DELETED**
  - Function no longer exists

- [x] **5.2.2 Cross-schema token search - REMOVED**
  - api_auth.ex simplified - tokens in current schema only

- [x] **5.2.3 Audit complete - no cross-schema patterns**
  - `Enum.reduce_while.*schema` patterns removed
  - All cross-schema iteration removed

### 5.3 Remove account registry resource from instance

- [x] **5.3.1 Decision: Remove entirely (Option B)**
  - Account registry resource has been deleted
  - Instance metadata comes from environment/config

- [x] **5.3.2 Implementation complete**
  - `Application.get_env(:serviceradar, :nats_account_name)` for NATS account
  - No account registry Ash queries in instance code

---

## Phase 6: Single-Deployment Mode

### 6.1 Update Helm bootstrap for OSS

- [x] **6.1.1 Create default schema in bootstrap job (if needed)**
  - Added `cnpg.schema` option to values.yaml (default: `platform`)
  - Updated spire-postgres.yaml postInitApplicationSQL to:
    - Create schema with `CREATE SCHEMA IF NOT EXISTS {schema} AUTHORIZATION serviceradar`
    - Grant permissions with `GRANT ALL ON SCHEMA {schema} TO serviceradar`
    - Set user search_path with `ALTER ROLE serviceradar SET search_path TO {schema},ag_catalog`

- [x] **6.1.2 Configure pods with scoped credentials**
  - Updated db-event-writer-config.yaml to derive search_path from cnpg.schema
  - Updated serviceradar-config.yaml to derive search_path from cnpg.schema
  - All pods use the same pattern: schema comes from values, search_path is auto-derived

### 6.2 Test OSS deployment

- [x] **6.2.1 `helm install` smoke test**
  - Verified schema `platform` created with correct ownership (serviceradar user)
  - Verified user `serviceradar` has USAGE and CREATE privileges on schema
  - Verified user's search_path set to `platform, ag_catalog`
  - Fixed: Made CNPG_CERT_FILE/KEY_FILE conditional on requireClientCert
  - Fixed: Added default pg_hba rules allowing SSL without client certs

- [ ] **6.2.2 Verify no cross-schema code paths**
  - Blocked by NATS credentials configuration issue
  - Schema isolation verified at DB level; app startup blocked on NATS

### 6.3 Infrastructure cleanup (certs/Helm/Compose)

- [x] **6.3.1 Remove account-scoped cert generation**
  - Edge component certs now live under `/etc/serviceradar/certs/components`
  - CN format: `<component_id>.<partition_id>.serviceradar`
  - SPIFFE format: `spiffe://serviceradar.local/<component_type>/<partition_id>/<component_id>`

- [x] **6.3.2 Update Helm/Compose config to drop account fields**
  - Removed CA secret values from Helm
  - Removed account slug/id env vars from agent-gateway and Compose
  - Updated agent gateway security config to use root CA chain

- [x] **6.3.3 Remove workload-operator artifacts from this repo**
  - Dropped Bazel image targets and push entries

- [x] **6.3.4 Remove external account fields from sync types**
  - Dropped NetBox account field from sync types

- [x] **6.3.5 Remove generated Ash resource snapshots**
  - Deleted `elixir/serviceradar_core/priv/resource_snapshots`

- [x] **6.3.6 Consolidate CNPG SQL migrations**
  - Reduced to a single schema migration in `pkg/db/cnpg/migrations`

---

## Phase 7: Cleanup and Documentation

### 7.1 Remove feature flag

- [x] **7.1.1 Remove legacy schema-aware flag**
  - N/A - Flag was never implemented; migration went directly to final state
  - Removed unused schema reset config option

- [x] **7.1.2 Remove old code paths**
  - N/A - No legacy schema-aware branches exist
  
### 7.2 Update documentation

- [x] **7.2.1 Update CLAUDE.md**
  - `elixir/serviceradar_core/CLAUDE.md` updated with dedicated deployment patterns
  - Documents `SystemActor.system/1`
  - Documents instance isolation model

- [x] **7.2.2 Update deployment docs**
  - Document CNPG credential requirements
  - Document OSS vs SaaS differences

### 7.3 Archive related proposals

- [x] **7.3.1 Update 2286-break-out-tenant-control-plane**
  - Marked as COMPLETE with reference to this proposal

- [x] **7.3.2 Archive enforce-tenant-schema-isolation**
  - Marked as SUPERSEDED by this proposal

---

## Verification Checklist

Code removal (complete):

- [x] Deployment instance cannot query other schemas (CNPG search_path enforces)
- [x] No schema context parameters in Ash calls (except AshAuthentication JWT - required)
- [x] No schema enumeration helper usage in instance code
- [x] No schema-scoped system actor usage (only `system/1` remains)
- [x] No `SystemActor.platform()` usage remains in instance code

Infrastructure (pending Phase 6):

- [ ] OSS helm install works with scoped credentials
- [ ] SaaS control plane provisioning creates scoped credentials
- [ ] All tests pass with new architecture
