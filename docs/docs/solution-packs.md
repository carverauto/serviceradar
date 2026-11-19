---
title: Solution Packs & Declarative Checks
---

# Solution Packs & Declarative Checks

ServiceRadar **Declarative Service & Posture Checks** and **Solution Packs** turn active monitoring, derived multi-signal verdicts, alert rules, and authored dashboards into portable, secret-free JSON artifacts that can be visually edited, packaged into deterministic `.srpack` archives, distributed through ed25519-signed catalogs, and promoted across `dev -> staging -> prod` through private GitOps repositories.

- **Declarative Checks UI**: **Settings -> Declarative Checks** (`/settings/declarative-checks`)
- **Catalog & Solution Packs Gallery**: **Catalog** (`/catalog` and `/settings/catalog`)
- **Unified Credentials**: **Settings -> System -> Security -> Credentials and Rules** (`/settings/networks/credentials`)

---

## Declarative Service & Posture Checks

Every declarative check is stored in CNPG (`platform.declarative_checks`) as a versioned (`schema_version: 1`), secret-free JSONB Directed Acyclic Graph (DAG). Checks never execute user-supplied JavaScript, Lua, shell commands, or raw SQL; every node belongs to a closed, schema-validated operator family.

### Two-Way Visual Canvas Builder (`/settings/declarative-checks`)

Opening a check at `/settings/declarative-checks/:slug` launches the two-way visual pipeline builder backed by:

- **Palantir Blueprint v6** (`@blueprintjs/core`, `@blueprintjs/icons`, `@blueprintjs/select`) strictly CSS-scoped inside `.sr-bp6-scope` (with `.bp6-dark` theme sync and a local `portalContainer` so Blueprint never alters Tailwind v4 or daisyUI layout outside the canvas).
- **`@xyflow/react`** for interactive drag-and-drop node wiring and **`elkjs`** (`layered` algorithm, `elk.direction = "RIGHT"`) for deterministic auto-layout.
- **Monaco JSON editor** synchronized bidirectionally with the visual graph: editing nodes or properties on the canvas formats canonical 2-space JSON immediately, while editing Monaco JSON validates against the `schema_version: 1` schema (with inline error diagnostics) and updates the canvas.

Four 1-click starter graphs are available when creating a new check:

1. **HTTP JSON API Check**
2. **SRQL Posture Check**
3. **Multi-Step Synthetic Journey**
4. **Multi-Vantage Composite Check**

Clicking **Test Run** (requires `declarative_checks.evaluate`) executes an ephemeral sandbox evaluation and decorates each canvas node with live status, `duration_ms`, extracted fields, redacted inputs (`"[REDACTED]"` for brokered credentials), and the final verdict without mutating `platform.service_state` or opening alert incidents.

Existing `ServiceCheck` and `CompositeCheck` resources continue operating unchanged. Operators can clone legacy checks into `draft` declarative check DAGs via 1-click import adapters, verify parity with **Test Run**, and cut over without dual-alerting.

### Core vs Edge Execution Runners

The DAG compiler routes each check graph to the appropriate runner without requiring custom per-check Wasm builds:

| Topology | Node Families | Execution Runner |
| --- | --- | --- |
| **Core-Only** | `srql_query` (bounded read-only SRQL via AshAdapter), `platform_posture` (closed first-party posture registry), plus `extract_field`, `threshold_assert`, `decision_table`, `alert_output` | Executed directly in `serviceradar_core` by Oban (`CoreEvaluationWorker`). Zero Wasm or agent assignment overhead. |
| **Edge-Only** | `http_request`, `http_journey` (with `httptrace` phase waterfalls: `dns_ms`, `tcp_ms`, `tls_ms`, `ttfb_ms`, `transfer_ms`, `total_ms`), `tcp_connect`, `tls_handshake` (`leaf_days_remaining`), `dns_lookup` | Compiled by `DeclarativeCheckAssignmentCompiler` into plugin assignments targeting the single first-party `declarative-check-runner` WASI plugin (`io.serviceradar.declarative-check-runner`) on `serviceradar-agent`. Credentials are injected by the agent host via `SecretBroker` grants, and results flow through `RecordSpool` -> NATS JetStream -> `EventWriter`. |
| **Hybrid Edge + Core** | Edge signal branches from one or more agents combined with Core `srql_query` or `platform_posture` signals into a `decision_table` -> `alert_output` | Edge branches persist per-agent signal observations via `declarative-check-runner`; `CoreEvaluationWorker` combines Core signals with fresh Edge observations (enforcing per-input `max_age_seconds` staleness -> `unknown` and a mandatory all-`*` catch-all row). |

### Target Bindings and Verdict Projection

A single `target_binding` contract handles both singleton posture checks and fleet fan-out:

- **`singleton`**: Evaluates once per schedule tick (`target_key: "singleton"`). Used for control-plane posture checks or a single external API endpoint.
- **`srql_devices`**: Evaluates across a paged `in:devices ...` SRQL population (`target_key: "device:<device_uid>"`), automatically pruning stale rows when devices leave scope and reassigning instances on DIRE device merges.
- **`service_targets`**: Evaluates across standalone or device-linked `ServiceTarget` records (`target_key: "service:<service_target_id>"`).

Every instance materializes its verdict (`healthy`, `degraded`, `down`, or `unknown`) in `platform.declarative_check_instances`, projects availability into `platform.service_state` (`service_type: "declarative_check"`), and publishes OCSF `health.state_change` events to NATS JetStream for `StatefulAlertRule` incident promotion.

### Built-in Pack #1: Storage Entitlements & NVR Recording Health

ServiceRadar ships **Built-in Pack #1** (`io.serviceradar.storage-and-nvr-health`) offline inside `serviceradar_core` using the standard `pack_format_version: 1` format. It monitors SaaS Storage Entitlements (PR `#6760`) and NVR continuous recording liveness through four `platform_posture` evaluators, companion `StatefulAlertRule` templates, and an overview authored dashboard:

| Evaluator | Check Slug | What It Monitors |
| --- | --- | --- |
| `storage.entitlement_utilization` | `storage-entitlement-utilization` | Compares `billable_bytes / plan_bytes` (default warn `>= 85%`, crit `>= 95%`, immediate `down` at `>= 100%` or `hard_cap_active`). On self-hosted deployments, evaluates against `RecordingArchiveSettings.object_budget_bytes` when bounded. |
| `storage.hold_pin_pressure` | `storage-hold-pin-pressure` | Measures active `:accepted` `RecordingHold` pinned archive bytes (`PD5` `non_reapable_bytes`) as a share of the archive budget so operators are warned before evidence holds starve normal retention. |
| `storage.archive_credential_and_usage_health` | `storage-archive-credential-health` | Verifies that `:local_and_archive` deployments have active `:writer` (`:uploader`), `:reader`, and `:retention` credentials in `platform.network_credential_secrets` and that the newest `StorageUsageDailyReport` is not stale (`> 36h` default). |
| `camera.continuous_recording_silence` | `camera-continuous-recording-silence` | Verifies that every enabled `continuous` `CameraRecordingPolicy` (when not operator-suspended) has sealed at least one non-quarantined `RecordingCatalogEntry` block within `silence_window_minutes` (default `15`). |

---

## Solution Pack Format (`pack_format_version: 1`)

A Solution Pack is an immutable, secret-free directory tree that maps 1:1 to a deterministic `.srpack` archive.

### Directory Tree Layout

```text
packs/storage-and-nvr-health/
  manifest.json
  README.md
  checks/
    entitlement-utilization.json
    hold-pin-pressure.json
    archive-credential-health.json
    camera-recording-silence.json
  rules/
    storage-hard-cap-alert.json
    camera-silence-alert.json
  dashboards/
    storage-and-nvr-overview.json
  assets/
    architecture.svg
```

- **`manifest.json`**: Declares `pack_format_version: 1`, reverse-DNS `id`, `slug`, `name`, SemVer `version`, `author`, `license`, `min_serviceradar_version`, `categories`, sanitized inline SVG `icon`, `description`, typed `config` parameters, abstract `credential_slots`, optional Wasm `plugin_dependencies`, `resources` references, and a complete `files` SHA-256 digest map.
- **`checks/*.json`**: Canonical `schema_version: 1` `DeclarativeCheck` DAG definitions.
- **`rules/*.json`**: `StatefulAlertRule`, `EventRule`, and `ZenRule` definitions. Each rule entry supports `"install_state": "enabled" | "paused"` so high-sensitivity detection rules can install paused for baseline inspection without being re-enabled on upgrade. A `StatefulAlertRule` `match` (and its `recovery` clause) may only use keys the alert engine reads, such as `subject_prefix` and `attribute_equals`; to alert on a check transition, match `subject_prefix: "declarative_check.health.state_change"` with `attribute_equals: {"check_slug": ..., "to_status": ...}`. Validation rejects any other key (`unknown_match_key`), because the engine would ignore it and match every event. A rule that covers a status should not also have that status in the check's `alert_policy.open_on_statuses`, or one condition raises two alerts.
- **`dashboards/*.json`**: Portable authored dashboard JSON documents.
- **`README.md` and `assets/*`**: Documentation and sanitized SVG/image previews rendered in the Catalog Gallery.

### Deterministic `.srpack` Archive Contract

The primary archive format is `tar.zst` (`.srpack`), built with:

- Lexicographically sorted relative paths
- Normalized POSIX ustar headers (`uid=0`, `gid=0`, `uname=""`, `gname=""`, `mtime=0`, file mode `0644`)
- Zstandard compression level `3` with no timestamp header

Browser and API upload endpoints also accept `.zip` archives with sorted entries. `ServiceRadar.Catalog.PackArchive` enforces strict safety bounds on every upload and catalog download:

- **25 MB** compressed size limit, **64 MB** total uncompressed limit, **256** maximum entries
- Fail-closed rejection of `..` path traversal, leading `/`, symlinks, hardlinks, device nodes, and unlisted files
- Mandatory exact SHA-256 verification of every file against `manifest.files`
- Server-side allowlist SVG sanitization (stripping `<script>`, `<foreignObject>`, `on*` handlers, and external URLs) and HTML sanitization for `README.md`

### Typed Parameters, `credential_slots`, and the Secret-Free Guarantee

Packs never contain plaintext secrets, AshCloak ciphertext, API tokens, PATs, SNMP community strings, private keys, or instance-local `credential_secret_id` / `credential_rule_id` UUIDs.

1. **Typed parameters**: Resource templates bind declared `manifest.json` `config` keys using `{"$pack_param": "<key>"}` in scalar positions (check input defaults, thresholds, schedule intervals, rule windows, and dashboard variable defaults), validated against `type`, `min`, `max`, and `enum` constraints at install and upgrade time.
2. **Abstract `credential_slots`**: Both `manifest.json` and `checks/*.json` declare abstract slots:

```json
{
  "slot": "target_http_api",
  "provider": "generic_http",
  "role": "bearer_token",
  "purpose": "Authenticate synthetic HTTP API health requests",
  "required": true
}
```

During installation, the Guided Install Wizard binds each slot to a local `NetworkCredentialRule` (preferred dynamic target-scoped resolution) or `NetworkCredentialSecret` in `platform.installed_solution_pack_credential_bindings` and `platform.declarative_check_credential_bindings`. See [Credential Management](./credentials.md#declarative-checks-solution-packs-and-catalog-repositories) for guarded deletion and usage tracking details.

3. **Export and GitOps push guard (`SecretFreeValidator`)**: Exporting a pack from `web-ng` or pushing to GitOps uses allowlist serialization to strip instance UUIDs and credential binding IDs, then scans every key and string literal for forbidden secret names (`password`, `secret`, `private_key`, `api_key`, `access_token`, `community_string`, etc.) and token prefixes (`ghp_`, `github_pat_`, `glpat-`, `xoxb-`, `eyJ`, `-----BEGIN`). Any match aborts before an archive or Git blob is written.

### Managed Upgrades and `parameter_overrides`

Every pack-managed `DeclarativeCheck`, `StatefulAlertRule`, `EventRule`, `ZenRule`, and authored `Dashboard` carries `RuleSeeder`-style provenance columns:

- `pack_id` and `pack_version`
- `managed` (`true` while reconciled by `ServiceRadar.Catalog.Reconciler`)
- `template_fingerprint` (lowercase SHA-256 hex digest of canonical structural template fields, excluding `ui_layout`, `state`, and `parameter_overrides`)
- `parameter_overrides` (operator-owned map of tuned config values, thresholds, schedule cadence, and `enabled` toggles)

When upgrading a pack (for example `0.1.0 -> 0.2.0`):

- **Unmodified managed resources** (`managed: true` and current structural fingerprint matches `template_fingerprint`) are upgraded automatically to `0.2.0` while preserving `parameter_overrides` and local `credential_slots` bindings.
- **Diverged or detached resources** (`template_fingerprint` mismatch or `managed: false`) are never silently overwritten. The Guided Upgrade Wizard opens a side-by-side Monaco diff allowing the operator to **Keep Customized (Detach `managed: false`)** or **Reset to Upstream**.
- **Interactive edit guard**: Tuning a parameter, threshold, schedule, or `enabled` toggle on a managed resource saves cleanly to `parameter_overrides` and keeps `managed: true`. Structural edits (adding/removing DAG nodes or rewriting SRQL queries) prompt the operator to confirm detaching/forking (`managed: false`).

---

## CLI Workflow (`@carverauto/serviceradar-cli`)

`@carverauto/serviceradar-cli` (`serviceradar` / `serviceradar-cli`) provides offline validation, deterministic `.srpack` packaging, ed25519 signing/verification, and release catalog index generation.

### 1. Validate a pack directory or archive

```bash
serviceradar pack validate ./packs/example-http-health
serviceradar pack validate ./dist/example-http-health-0.1.0.srpack --json
```

Validates `manifest.json`, SemVer, SVG allowlist safety, `checks/*.json`, `rules/*.json`, `dashboards/*.json`, `manifest.files` SHA-256 digests, and `SecretFreeValidator`. Exits non-zero if any secret-like field or unlisted file is present.

### 2. Build a deterministic `.srpack` archive

```bash
serviceradar pack build ./packs/example-http-health \
  --refresh-files \
  -o ./dist/example-http-health-0.1.0.srpack
```

Recomputes `manifest.files` SHA-256 digests (`--refresh-files`, optionally persisting back to disk with `--write-manifest`), validates the tree, and emits a byte-for-byte deterministic `tar.zst` archive.

### 3. Generate an ed25519 signing keypair

```bash
serviceradar pack keygen --out-dir ./keys --key-id example-pack-signing-1
```

Creates a base64 ed25519 private key seed and matching public key for `UploadSignature` signing. Store the private key in your CI secret manager (`PACK_UPLOAD_SIGNING_PRIVATE_KEY` or `PACK_UPLOAD_SIGNING_PRIVATE_KEY_FILE`) and register the public key and `key_id` on the corresponding `CatalogRepository` in ServiceRadar.

### 4. Sign and verify a `.srpack` archive

```bash
serviceradar pack sign ./dist/example-http-health-0.1.0.srpack \
  --key ./keys/example-pack-signing-1.key \
  --key-id example-pack-signing-1 \
  --signer "Example Monitoring Team" \
  -o ./dist/example-http-health-0.1.0.srpack.sig

serviceradar pack verify ./dist/example-http-health-0.1.0.srpack \
  --public-key ./keys/example-pack-signing-1.pub
```

`pack sign` signs the canonical JSON payload `{"content_hash":"<sha256>","manifest":<canonical-manifest>}` using ed25519, maintaining byte-for-byte parity with `ServiceRadar.Catalog.UploadSignature` and `ServiceRadarWebNG.Plugins.UploadSignature`.

### 5. Generate a release catalog index

```bash
serviceradar pack index ./dist \
  -o ./dist/serviceradar-pack-index.json \
  --repo example-org/serviceradar-packs \
  --release-tag v0.1.0
```

Or for a static HTTPS portal host:

```bash
serviceradar pack index ./dist \
  -o ./dist/index.json \
  --base-url https://packs.example.com/releases/v0.1.0
```

Scans `.srpack` and `.srpack.sig` pairs and emits `serviceradar-pack-index.json` (`format_version: 1`) with embedded manifests, SHA-256 digests, resource counts, download URLs, and signature URLs.

---

## Signed Release Catalogs

`ServiceRadar.Catalog.CatalogRepository` (`platform.catalog_repositories`) manages external pack sources in two modes: `:release_catalog` and `:gitops_tree`.

### Public ServiceRadar Developer Portal & Official Catalog

- **Public ServiceRadar Developer Portal**: Browse published first-party and community Solution Packs at `https://developer.serviceradar.cloud/packs`, backed by the signed HTTPS portal index at `https://developer.serviceradar.cloud/packs/index.json`.
- **Seeded Official Repository**: Every ServiceRadar deployment seeds `https://github.com/carverauto/serviceradar` (`mode: :release_catalog`, `builtin: true`, `is_default: true`) with trusted first-party ed25519 keys. Built-in repositories can be enabled or disabled but cannot be modified or deleted.

### Third-Party ed25519-Signed Catalogs

Administrators (`catalog.repositories.manage`) can register additional public or private `:release_catalog` sources in **Catalog -> Manage Repositories**:

1. Choose **Release Catalog** (`mode: :release_catalog`) and provider (`portal`, `github`, or `gitea`).
2. Enter the portal index URL (for example `https://packs.example.com/packs/index.json`) or GitHub/Gitea repository URL (`https://github.com/example-org/serviceradar-packs`) and index asset name (default `serviceradar-pack-index.json`).
3. Supply the repository's `signing_key_id` and base64 ed25519 `signing_public_key`.
4. For private release repositories, bind an AshCloak-encrypted `:api_token` PAT from `platform.network_credential_secrets`.

Every `.srpack` downloaded from a release catalog is fetched through `ServiceRadar.HTTP.EgressClient` (stripping `Authorization` headers across cross-origin pre-signed asset redirects) and verified against *that repository's* ed25519 public key before extraction or preview. Private release catalogs do not invoke public transparency logs (such as Sigstore Rekor), keeping private repository metadata confidential.

---

## Two-Way Private GitOps Tree Sync (`dev -> staging -> prod`)

For teams promoting monitoring packs across environments through Git code review, `CatalogRepository` supports `mode: :gitops_tree` for **GitHub**, **GitLab**, and **Gitea / Forgejo**.

### Pure-HTTPS Transport (Zero Host `git` or SSH Keys)

All GitOps reads and writes run strictly over HTTPS Git Data REST APIs through `ServiceRadar.HTTP.EgressClient` (respecting `SERVICERADAR_EGRESS_PROXY` and workspace TLS trust anchors, with `redirect: false` on mutating JSON calls so tokens and payloads never cross origin boundaries):

- **Zero host `git` binaries** or persistent git worktrees in ServiceRadar pods.
- **Zero SSH private keys** on pod filesystems.
- Authentication uses an AshCloak-encrypted `:api_token` PAT stored in `platform.network_credential_secrets`, decrypted only at sync time inside `serviceradar_core` and never exposed in UI assigns or audit events.

### Connecting a GitOps Repository

1. Create a scoped repository PAT in **Settings -> System -> Security -> Credentials and Rules** (`/settings/networks/credentials`).
2. In **Catalog -> Manage Repositories**, add a `gitops_tree` repository:
   - **Provider**: `github`, `gitlab`, or `gitea`
   - **Repository URL**: e.g. `https://github.com/example-org/monitoring-packs`
   - **Branch**: e.g. `staging` or `main`
   - **Base Path**: directory prefix inside the repo (default `packs`)
   - **Push Strategy**: `pull_request` (default -- creates branch `serviceradar/pack-<slug>-v<version>-<shortsha>` and opens a PR/MR) or `direct_commit` (optimistic parent-SHA check, `force: false` always)
   - **Credential**: select the `:api_token` secret created in step 1

### Promotion Workflow (`dev -> staging -> prod`)

1. **Author & test in `dev`**: Build checks in `/settings/declarative-checks`, tune alert rules and dashboards, and validate with **Test Run**.
2. **Export & push to Git**: In `/catalog`, click **Export as Pack -> Push to GitOps Repository** (requires `catalog.packs.export` and `catalog.gitops.sync`). ServiceRadar strips local UUIDs and credential bindings, runs `SecretFreeValidator`, and commits `<base_path>/<slug>/...` via a Pull Request / Merge Request.
3. **Review & merge**: Reviewers inspect human-readable JSON diffs in GitHub, GitLab, or Gitea and merge into the target environment branch.
4. **Pull & reconcile in `staging` and `prod`**: `CatalogSyncWorker` periodically checks connected repositories and displays an **Update Available** badge (human confirmation by default unless `auto_reconcile: true` is explicitly enabled). Operators run a dry-run preview showing created, upgraded, unchanged, and diverged resources, bind environment-local `credential_slots` on first install, and apply atomically. Every push and pull emits an OCSF audit event recording actor, repository URL, branch, pack version, commit SHA, and PR URL.

---

## Related Pages

- [Roles & Permissions](./rbac-and-roles.md#declarative-checks-and-solution-packs)
- [Credential Management](./credentials.md#declarative-checks-solution-packs-and-catalog-repositories)
- [Camera Recording & NVR](./camera-recording.md)
- [Wasm Plugins](./wasm-plugins.md)
- [Self-Authored Dashboards](./self-authored-dashboards.md)
- [ServiceRadar CLI](./cli-reference.md)
