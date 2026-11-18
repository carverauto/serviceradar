## Context

ServiceRadar is introducing declarative service and posture check DAGs (`add-declarative-service-and-posture-checks`) alongside existing observability rules (`StatefulAlertRule`, `EventRule`, `ZenRule`), portable authored dashboards (`ServiceRadarWebNG.Dashboards.Authored`), and signed Wasm plugins (`ServiceRadar.Plugins.PluginPackage` and `PluginRepository` from `add-third-party-plugin-repositories`).

Inspired structurally by Timeplus Apps (`timeplus-io/apps`, where each package bundles a manifest with typed `config` inputs, inline SVG icon, categories, modular pipeline resources, dashboards, `README.md`, and a static `index.json` catalog), ServiceRadar Solution Packs elevate monitoring from individual check or rule forms into versioned, composable, secret-free monitoring bundles that can be:
1. Browsed and installed in one guided flow from a `web-ng` Catalog Gallery.
2. Distributed as deterministic `.srpack` archives from signed public or private release catalogs (`carverauto/serviceradar-apps` and third-party repositories).
3. Committed and promoted across `dev -> staging -> prod` as clean human-readable Git directory trees (`packs/<slug>/...`) in private GitHub, GitLab, or Gitea repositories via pure HTTPS REST APIs over `ServiceRadar.HTTP.EgressClient`.
4. Upgraded safely across versions (`0.1.0 -> 0.2.0`) using `RuleSeeder`-style `managed` + `template_fingerprint` reconciliation without clobbering operator `parameter_overrides` or threshold customizations.

## Goals / Non-Goals

**Goals**
- Define a deterministic, secret-free Solution Pack contract (`pack_format_version: 1`) with identical semantics whether stored as a Git directory tree or packaged into a `.srpack` archive.
- Guarantee zero secret leakage in packs, browser exports, and GitOps commits by enforcing structural allowlists, secret scanning, and abstract `credential_slots` bound locally to `platform.network_credential_secrets` or `platform.network_credential_rules`.
- Generalize `ServiceRadar.Observability.RuleSeeder`'s `managed` + `template_fingerprint` pattern across `DeclarativeCheck`, `StatefulAlertRule`, `EventRule`, `ZenRule`, and authored `Dashboard` resources with structured `parameter_overrides`.
- Deliver a first-class Catalog / Solution Packs Gallery LiveView in `web-ng` with search, category pills, SVG icons, "What's inside" counts, rendered `README.md`, interactive DAG/JSON preview, upgrade diff viewer, and guided install wizard.
- Harmonize catalog repository management (`ServiceRadar.Catalog.CatalogRepository`) with `PluginRepository`: per-repository ed25519 `UploadSignature` verification for `:release_catalog` sources and pure-HTTPS Git Data REST sync for `:gitops_tree` sources over `ServiceRadar.HTTP.EgressClient`.
- Ship `serviceradar-cli pack validate|build|sign|index` in `@carverauto/serviceradar-cli` (`js/cli`) and Built-in Pack #1 (`io.serviceradar.storage-and-nvr-health`).

**Non-Goals**
- Arbitrary executable code or raw SQL inside Solution Packs. Checks use only the typed safe node families from `add-declarative-service-and-posture-checks`; rules compile through Ash/Zen validators; dashboards use the declarative `authored-dashboards` / Dashboard SDK schema; optional Wasm plugins remain governed by `wasm-plugin-system` approval and capability review.
- Shelling out to a host `git` binary, mounting persistent git worktrees in pods, or storing SSH deploy keys on pod filesystems. All remote catalog and GitOps network I/O uses HTTPS via `ServiceRadar.HTTP.EgressClient`.
- Public Sigstore Rekor transparency logging for third-party or private repositories. Private repositories use per-repository ed25519 `UploadSignature` keys and AshCloak-encrypted PATs in `platform.network_credential_secrets`.
- Unattended destructive auto-upgrades of operator-diverged resources. Any managed resource whose structural fields diverge from `template_fingerprint` is preserved and surfaced in the upgrade diff viewer.

## Decisions

### Decision 1: Dual Canonical Representation (`pack_format_version: 1` Git Directory Tree and `.srpack` Archive)

A Solution Pack is an immutable directory tree with a 1:1 lossless mapping to a `.srpack` archive:

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

**`manifest.json` contract (`pack_format_version: 1`):**

```json
{
  "pack_format_version": 1,
  "id": "io.serviceradar.storage-and-nvr-health",
  "slug": "storage-and-nvr-health",
  "name": "Storage Entitlements & NVR Recording Health",
  "version": "0.1.0",
  "author": "ServiceRadar",
  "license": "Apache-2.0",
  "min_serviceradar_version": "1.0.70",
  "categories": ["Storage & NVR", "Infrastructure"],
  "icon": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PC9zdmc+",
  "description": "Monitors archive storage entitlement quota, PD5 hold-pin retention pressure, S3 role credential health, and continuous camera recording silence.",
  "config": [
    {
      "key": "utilization_warn_pct",
      "type": "number",
      "required": false,
      "default": 85,
      "min": 1,
      "max": 100,
      "description": "Warning threshold percentage for billable storage utilization."
    },
    {
      "key": "utilization_crit_pct",
      "type": "number",
      "required": false,
      "default": 95,
      "min": 1,
      "max": 100,
      "description": "Critical threshold percentage for billable storage utilization."
    },
    {
      "key": "silence_window_minutes",
      "type": "integer",
      "required": false,
      "default": 15,
      "min": 5,
      "max": 1440,
      "description": "Minutes with zero sealed blocks on an enabled continuous recording policy before alerting."
    }
  ],
  "credential_slots": [],
  "plugin_dependencies": [],
  "resources": {
    "checks": [
      { "file": "checks/entitlement-utilization.json", "slug": "storage-entitlement-utilization" },
      { "file": "checks/hold-pin-pressure.json", "slug": "storage-hold-pin-pressure" },
      { "file": "checks/archive-credential-health.json", "slug": "storage-archive-credential-health" },
      { "file": "checks/camera-recording-silence.json", "slug": "camera-continuous-recording-silence" }
    ],
    "rules": [
      {
        "file": "rules/storage-hard-cap-alert.json",
        "kind": "stateful_alert_rule",
        "name": "storage_entitlement_hard_cap",
        "install_state": "enabled"
      },
      {
        "file": "rules/camera-silence-alert.json",
        "kind": "stateful_alert_rule",
        "name": "camera_continuous_recording_silence",
        "install_state": "enabled"
      }
    ],
    "dashboards": [
      { "file": "dashboards/storage-and-nvr-overview.json", "slug": "storage-and-nvr-overview" }
    ]
  },
  "files": {
    "README.md": "0000000000000000000000000000000000000000000000000000000000000001",
    "checks/archive-credential-health.json": "0000000000000000000000000000000000000000000000000000000000000002",
    "checks/camera-recording-silence.json": "0000000000000000000000000000000000000000000000000000000000000003",
    "checks/entitlement-utilization.json": "0000000000000000000000000000000000000000000000000000000000000004",
    "checks/hold-pin-pressure.json": "0000000000000000000000000000000000000000000000000000000000000005",
    "dashboards/storage-and-nvr-overview.json": "0000000000000000000000000000000000000000000000000000000000000006",
    "rules/camera-silence-alert.json": "0000000000000000000000000000000000000000000000000000000000000007",
    "rules/storage-hard-cap-alert.json": "0000000000000000000000000000000000000000000000000000000000000008"
  }
}
```

**Deterministic `.srpack` archive rules:**
- Primary wire archive format is `tar.zst` (`.srpack`), with deterministic POSIX ustar headers: lexicographically sorted relative paths, `uid=0`, `gid=0`, `uname=""`, `gname=""`, `mtime=0`, file mode `0644`, zstd compression level `3` with no timestamp header. Browser and API upload endpoints also accept `.zip` archives with sorted entries and normalized DOS epoch timestamps for workstation convenience, normalizing both through `ServiceRadar.Catalog.PackArchive` with strict zip-slip/path-traversal rejection (`..`, leading `/`, symlinks, hardlinks, device nodes), a 25 MB compressed cap, a 64 MB total uncompressed cap, and a 256-entry cap.
- Every file in the archive (other than `manifest.json` itself) MUST appear in `manifest.files` with an exact lowercase SHA-256 hex digest, and unlisted files in `checks/`, `rules/`, `dashboards/`, or `assets/` cause validation to fail closed (matching `authored-dashboards` unlisted-file strictness).
- Inline SVG icons and `assets/*.svg` files pass through a strict server-side XML/SVG allowlist sanitizer (`<svg>`, `<defs>`, `<linearGradient>`, `<radialGradient>`, `<stop>`, `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polyline>`, `<polygon>`, `<path>`, `<g>`) that strips `<script>`, `<foreignObject>`, `on*` event attributes, and external `href`/`xlink:href` URLs before storage or rendering.

**Parameterization without arbitrary templating:**
- Rather than string-interpolating raw JSON text (which allows injection across JSON tokens), pack resource templates bind `config` keys through typed parameter references `{"$pack_param": "<key>"}` in allowed scalar value positions (check `inputs` defaults, `threshold_assert` thresholds, `schedule` intervals, rule `threshold` / `window_seconds` / `cooldown_seconds`, and dashboard variable defaults). At install/upgrade time, `ServiceRadar.Catalog.Reconciler` validates each resolved parameter value against the `manifest.json` `config` type (`string`, `integer`, `number`, `boolean`, `duration_seconds`, `srql_filter`) and `min`/`max`/`enum` constraints.
- Rule templates support `"install_state": "enabled" | "paused"` (modeled on `timeplus-apps` AgentGuard detection rules that can install paused so operators can inspect baseline noise before turning paging on). When `install_state` is `"paused"`, initial installation sets `enabled: false` and records `"enabled"` in operator-tunable fields so subsequent pack upgrades never re-enable a rule the operator left paused.

### Decision 2: Hard Secret-Free Guarantee and `credential_slots` Indirection

Packs and exports MUST NEVER contain plaintext secrets, AshCloak ciphertext, API tokens, PATs, SNMP community strings, private keys, or deployment-specific secret UUIDs.

1. **Abstract `credential_slots` contract (shared identically with `add-declarative-service-and-posture-checks`):**
   - Both `manifest.json` (pack-level summary) and individual `checks/*.json` documents declare `credential_slots` as entries of:
     ```json
     {
       "slot": "target_http_api",
       "provider": "generic_http",
       "role": "bearer_token",
       "purpose": "Authenticate synthetic HTTP API health requests",
       "required": true
     }
     ```
   - Inside check nodes (`http_request`, `http_journey`, etc.), authentication references `"credential_slot": "target_http_api"` -- never a `credential_secret_id` or `credential_rule_id`.
2. **Install-time binding via CNPG unified credentials:**
   - During pack installation in `web-ng` (or via REST API), each `credential_slot` is persisted in `ServiceRadar.Catalog.InstalledSolutionPackCredentialBinding` (`platform.installed_solution_pack_credential_bindings`) and projected into each installed check's `ServiceRadar.DeclarativeChecks.DeclarativeCheckCredentialBinding` (`platform.declarative_check_credential_bindings` from `add-declarative-service-and-posture-checks`) with real PostgreSQL `on_delete: :restrict` foreign keys to either:
     - `credential_rule_id` (`platform.network_credential_rules`, preferred dynamic target-scoped resolution, e.g. `"00000000-0000-4000-8000-000000000010"`), or
     - `credential_secret_id` (`platform.network_credential_secrets`, typed singleton binding, e.g. `"00000000-0000-4000-8000-000000000011"`).
   - At check execution time, `SecretBroker` mints short-lived `CredentialBrokerGrant` leases from those CNPG bindings exactly as specified in `add-declarative-service-and-posture-checks`. `parameter_overrides` never stores `credential_secret_id` or `credential_rule_id` UUIDs.
   - All `credential_secret_id` and `credential_rule_id` foreign keys across `platform.installed_solution_pack_credential_bindings`, `platform.declarative_check_credential_bindings`, and `platform.catalog_repositories` enforce `on_delete: :restrict` and are registered in `ServiceRadar.Credentials.CredentialUsage`, `GuardCredentialDestroy`, and `GuardCredentialRuleLifecycle` so an in-use secret or rule cannot be deleted silently and appears on the navigable credential usage surface in Settings -> Credentials.
3. **Export and GitOps push pre-flight `SecretFreeValidator`:**
   - Assembling a pack from live resources runs an explicit allowlist projection that strips database PKs (`id`), timestamps, actor IDs, `credential_secret_id`, `credential_rule_id`, and `encrypted_secret_payload`, omitting local binding rows from `platform.declarative_check_credential_bindings` / `platform.installed_solution_pack_credential_bindings` and emitting only abstract `credential_slots`.
   - Before writing any `.srpack` archive, HTTP export response, or GitOps blob, `ServiceRadar.Catalog.SecretFreeValidator` scans all JSON keys and string literals and rejects the export if any forbidden key (`password`, `secret`, `secret_payload`, `encrypted_secret_payload`, `private_key`, `api_key`, `access_token`, `session_token`, `auth_passphrase`, `priv_passphrase`, `community_string`, `authorization` bearer literals) or known token prefix (`ghp_`, `github_pat_`, `glpat-`, `xoxb-`, `eyJ` JWTs, PEM `-----BEGIN`) is present outside explicit placeholder syntax.

### Decision 3: `RuleSeeder`-Style Managed Provenance, `parameter_overrides`, and Safe Upgrades (`0.1.0 -> 0.2.0`)

To make Solution Pack upgrades predictable across checks, rules, and dashboards, we extend `ServiceRadar.Observability.RuleSeeder`'s proven reconciliation model (`managed` + `template_fingerprint`) to all pack-managed resources using identical field names across both proposals (`add-declarative-service-and-posture-checks` and `add-solution-packs-and-git-catalog`):

| Field | Type | Semantics |
|---|---|---|
| `pack_id` | `:string` (nullable) | Reverse-DNS identifier of the owning pack (e.g. `"io.serviceradar.storage-and-nvr-health"`), `nil` when standalone. |
| `pack_version` | `:string` (nullable) | SemVer version of the pack template currently materialized on the record (e.g. `"0.1.0"`). |
| `managed` | `:boolean` (`default: false`) | `true` while reconciled by `ServiceRadar.Catalog.Reconciler` (or `RuleSeeder`); clearing to `false` detaches/forks the resource permanently. |
| `template_fingerprint` | `:string` (nullable) | Lowercase SHA-256 hex digest of canonicalized template-owned structural fields (`RuleSeeder.canonical_term/1` semantics) *after* substituting baseline template defaults and *before* applying `parameter_overrides`. |
| `parameter_overrides` | `:map` (`default: %{}`) | Operator-owned map storing `{ "config" => %{...}, "thresholds" => %{...}, "schedule" => %{...}, "enabled" => bool }` (secret-free; credential slot bindings stay in `platform.installed_solution_pack_credential_bindings` and `platform.declarative_check_credential_bindings`). |

**Reconciliation truth table on pack upgrade (`0.1.0 -> 0.2.0`):**
1. **Unmodified managed resource (`managed == true` and current structural fingerprint matches stored `template_fingerprint`):**
   - Automatically updated to the `0.2.0` upstream template structure, re-applying stored `parameter_overrides` (preserving operator `config` values, threshold tweaks, schedule cadence, and `enabled` toggle) and preserving bound `credential_slots` rows in `platform.installed_solution_pack_credential_bindings` / `platform.declarative_check_credential_bindings`, updating `pack_version: "0.2.0"` and recomputing `template_fingerprint`.
2. **Structurally diverged resource (`managed == true` and current structural fingerprint != `template_fingerprint`) OR detached resource (`managed == false`):**
   - **Never silently overwritten.** This honors both `RuleSeeder.diverged_from_last_template?/1` and the `authored-dashboards` non-overwrite invariant.
   - In the Guided Upgrade Wizard's Diff Viewer, diverged/detached resources are highlighted side-by-side against the `0.2.0` template with two explicit per-resource choices: **Keep Customized (Detach `managed: false`)** (default) or **Reset to Upstream `0.2.0` (Re-attach `managed: true`, preserving compatible `parameter_overrides`)**.
3. **Removed resource in `0.2.0`:**
   - Flagged in the upgrade preview as orphaned by `0.2.0`; defaults to detaching (`managed: false`, `pack_id` retained in audit history) unless the operator explicitly checks **Archive/Delete removed resource**.
4. **Interactive edit guard in Check Canvas / Rule / Dashboard editors:**
   - When an operator edits a `managed: true` resource in `web-ng`:
     - Changing a declared input parameter, threshold knob, schedule, or `enabled` state saves cleanly into `parameter_overrides` while keeping `managed: true` and `template_fingerprint` intact.
     - Adding/deleting DAG nodes or edges, rewriting a panel SRQL query, or altering rule `match`/`signal` opens a confirmation prompt: **"Save as Detached Copy / Fork (`managed: false`)"** vs **"Cancel"**, preventing accidental silent drift.

### Decision 4: Harmonized `CatalogRepository` -- Signed Release Catalogs (`:release_catalog`) and Two-Way Private Git Tree Sync (`:gitops_tree`)

**Why `ServiceRadar.Catalog.CatalogRepository` (`platform.catalog_repositories`) is a dedicated sibling resource to `PluginRepository`:**
`ServiceRadar.Plugins.PluginRepository` (`elixir/serviceradar_core/lib/serviceradar/plugins/plugin_repository.ex`) enforces a unique index on `repo_url` (`plugin_repositories_repo_url_index`), requires `signing_key_id` + `signing_public_key` on every row, and restricts `repo_url` to `github.com` release assets. A Solution Pack catalog source, by contrast:
- May point at the same organization repository that also publishes Wasm plugins, or connect two branches (`staging` and `main`) of one GitOps repository.
- Supports two distinct transport modes (`:release_catalog` and `:gitops_tree`) across GitHub, GitLab, and Gitea/Forgejo HTTPS hosts.

We therefore define `ServiceRadar.Catalog.CatalogRepository` in the `ServiceRadar.Catalog` Ash domain, sharing the exact security building blocks of `PluginRepository`:
- `credential_secret_id` FK (`on_delete: :restrict`) referencing `ServiceRadar.Credentials.NetworkCredentialSecret` (`credential_kind: :api_token`), decrypted strictly at fetch/push time inside `serviceradar_core` and never exposed on reads, LiveView assigns, or audit events.
- Registered in `ServiceRadar.Credentials.CredentialUsage` and `GuardCredentialDestroy`.
- RBAC-gated writes (`catalog.repositories.manage`, admin-only, enforced in both LiveView and Ash policies) and OCSF audit records emitted via `ServiceRadar.Events.AuditWriter`.

#### Mode A: Signed Release Catalogs (`mode: :release_catalog`)
- **Seeded built-in catalog:** Migration seeds `https://github.com/carverauto/serviceradar-apps` (`name: "ServiceRadar Official Solution Packs"`, `mode: :release_catalog`, `builtin: true`, `is_default: true`, `index_asset_name: "serviceradar-pack-index.json"`, trusted first-party ed25519 signing keys). Like `PluginRepository`, `builtin: true` rows reject `:update` and `:destroy` while allowing `:enable` / `:disable`.
- **Third-party public & private release catalogs:** Operators add public or private GitHub/Gitea release repositories with mandatory `signing_key_id` + base64 ed25519 `signing_public_key` and optional `:api_token` PAT `credential_secret_id`.
- **Verification & transport:** `ReleaseCatalogClient` fetches `serviceradar-pack-index.json`, `.srpack`, and `.srpack.sig` via `ServiceRadar.HTTP.EgressClient` (using the API asset endpoint `Accept: application/octet-stream` for private GitHub/Gitea releases and stripping `Authorization` headers across cross-origin pre-signed asset redirects). Every `.srpack` archive's SHA-256 `content_hash` and decoded `manifest.json` MUST verify via `ServiceRadarWebNG.Plugins.UploadSignature.verify/4` against *that repository's* ed25519 public key before extraction or preview. No cosign or public Sigstore Rekor lookup is invoked, preserving repository privacy.

#### Mode B: Two-Way Private Git Tree Sync (`mode: :gitops_tree`)
- **Configuration:** Stores `provider_type` (`:github | :gitlab | :gitea`), `repo_url`, `branch` (e.g. `"main"` or `"staging"`), `base_path` (default `"packs"`), `push_strategy` (`:pull_request | :direct_commit`, default `:pull_request`), and required PAT `credential_secret_id` (`:api_token`).
- **Pure-HTTPS Git Data REST transport over `EgressClient` (zero host `git`, zero SSH keys on disk):**
  - Currently `ServiceRadar.HTTP.EgressClient` exposes `get/2`, `head/2`, `fetch_body/2`, `fetch_json/2`, `download_to_file/3`, and `fetch_range/3`. We extend `EgressClient` with `request_json(method, url, body_map, opts)` supporting `:post`, `:put`, and `:patch` over passive `Mint.HTTP` / `:httpc` through `SERVICERADAR_EGRESS_PROXY` and `tls_options/1`, enforcing `redirect: false` (3xx responses fail closed so bearer tokens and JSON payloads never cross origin boundaries) and bounded request/response byte caps.
  - **Push / Commit flow (`ServiceRadar.Catalog.GitOpsTreeClient.push_pack/4`):**
    1. Exports the selected pack (or set of authored checks, rules, and dashboards) into an in-memory secret-free file map under `<base_path>/<slug>/...` and passes `SecretFreeValidator` (aborting before any network call on violation).
    2. Resolves target branch HEAD commit SHA and base tree SHA via provider REST API:
       - **GitHub:** `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` -> `POST /repos/{owner}/{repo}/git/blobs` -> `POST /repos/{owner}/{repo}/git/trees` (creating/updating `<base_path>/<slug>/*` and setting `sha: null` on stale files removed from that pack subtree) -> `POST /repos/{owner}/{repo}/git/commits` -> either updates `PATCH /repos/{owner}/{repo}/git/refs/heads/{branch}` (`:direct_commit` with optimistic parent SHA check) or creates branch `serviceradar/pack-<slug>-v<version>-<shortsha>` + `POST /repos/{owner}/{repo}/pulls` (`:pull_request`).
       - **GitLab:** `POST /api/v4/projects/{id}/repository/commits` with atomic `actions` (`create` / `update` / `delete` scoped to `<base_path>/<slug>/`) targeting either `branch` (`:direct_commit`) or `start_branch` + `POST /api/v4/projects/{id}/merge_requests` (`:pull_request`).
       - **Gitea / Forgejo:** Git Data Trees/Commits API or atomic multi-file contents batch `POST /api/v1/repos/{owner}/{repo}/contents` + `POST /api/v1/repos/{owner}/{repo}/pulls`.
    3. Records the resulting commit SHA, branch, and PR/MR URL on `InstalledSolutionPack` / sync history and emits an OCSF audit record via `AuditWriter` (actor, repo URL, branch, pack ID, version, commit SHA, PR URL -- never the PAT).
  - **Pull / Environment Promotion flow (`dev -> staging -> prod`):**
    1. Reads `<base_path>/*/manifest.json` and referenced resource files at `branch` (or pinned commit SHA) via HTTPS REST tree/blob endpoints over `EgressClient`, validating path confinement, byte caps, JSON schemas, `manifest.files` SHA-256 digests, and `SecretFreeValidator`.
    2. Computes a dry-run reconciliation plan against `platform.installed_solution_packs` showing new, upgraded, unchanged, and operator-diverged resources before any CNPG write occurs.
    3. Applying the pull runs `ServiceRadar.Catalog.Reconciler` inside a transaction and emits an OCSF audit event recording source commit SHA and reconciled resource IDs.

### Decision 5: Optional Wasm `plugin_dependencies` Verification

A Solution Pack whose checks run only Core Signal Nodes (`srql_query`, `platform_posture`) or standard Edge Signal Nodes on the built-in `declarative-check-runner` Wasm plugin requires zero extra plugins (`"plugin_dependencies": []`). When a pack bundles checks or normalization pipelines for a specialized integration Wasm plugin (for example an external hardware or wireless telemetry plugin), `manifest.json` declares:

```json
"plugin_dependencies": [
  {
    "package_id": "io.example.wireless-controller",
    "version_constraint": ">= 0.2.0 and < 1.0.0",
    "required": true
  }
]
```

During the Guided Install Wizard:
- `ServiceRadar.Catalog.DependencyChecker` inspects `ServiceRadar.Plugins.PluginPackage` for an `:approved` package matching `package_id` and `version_constraint`.
- If the dependency is `:staged` awaiting admin capability approval or available in an enabled `PluginRepository`, the wizard surfaces its status with a direct review/import link (respecting `plugins.stage` / `plugins.approve` RBAC -- Solution Pack install NEVER auto-approves Wasm capabilities silently).
- Required missing/unapproved plugin dependencies block activation of the pack (or allow installing checks in `paused` state when the operator chooses staged setup).

### Decision 6: Catalog Gallery UI in `web-ng` (Modeled on `demos.timeplus.com` / `timeplus-io/apps`)

We add a top-level **Catalog** (`Solution Packs`) LiveView in `elixir/web-ng/lib/serviceradar_web_ng_web/live/catalog_live/`:
- **Navigation & Layout:** Accessible under Observability / Monitoring navigation (`/catalog`), using daisyUI cards, badges, tabs, and modals per `elixir/web-ng` UI conventions, mounting the scoped React/Blueprint v6 read-only `@xyflow/react` DAG preview and Monaco JSON/diff tabs inside the pack detail and upgrade drawers.
- **Discovery Controls:**
  - Instant search input (matching pack `name`, `id`, `description`, check/rule/dashboard slugs, and `author`).
  - Category filter pills: `All`, `Storage & NVR`, `Network & WAN`, `Synthetic HTTP`, `Security & Posture`, `Infrastructure`.
  - Repository source filter (`All Sources`, `Official`, third-party release catalogs, connected GitOps repositories) + `Installed` vs `Available` vs `Updates Available` tabs.
- **Pack Cards:** Sanitized inline SVG icon, pack title, SemVer badge, publisher/source trust badge (`Built-in`, `Signed Release`, `GitOps Tree`, `Local Upload`), short description, and **"What's inside" badges** (`4 checks * 2 alert rules * 1 dashboard`).
- **Pack Detail & Preview Drawer/Page:**
  - Rendered sanitized `README.md` + `assets/*` architecture/screenshot carousel.
  - Tabbed resource inspector: interactive read-only `@xyflow/react` DAG preview for every check, Monaco JSON viewer for check/rule/dashboard templates, declared `config` inputs table, `credential_slots` table, and `plugin_dependencies` check.
- **4-Step Guided Install / Upgrade Wizard:**
  1. **Parameters (`config`)**: Typed form inputs with defaults, `min`/`max` validation, and inline descriptions.
  2. **Credentials (`credential_slots`) & Plugins (`plugin_dependencies`)**: Selector binding each slot to an existing compatible `NetworkCredentialRule` or `NetworkCredentialSecret` (filtered by `provider` / kind), plus an inline **"Create Credential"** link opening the unified Settings -> Credentials flow, and plugin dependency readiness badges.
  3. **Preview & Diff**: Summary of checks, rules (showing `enabled` vs `paused` install state), and dashboards to create or reconcile; on upgrade (`0.1.0 -> 0.2.0`), displays a side-by-side Monaco structural diff and per-resource conflict resolution for any diverged resource.
  4. **Apply & Verify**: Atomic install/reconcile execution with links to open the installed dashboard, inspect live `ServiceState` check verdicts, or push overrides to GitOps.
- **1-Click Browser Import / Export & GitOps Push Modal:**
  - **Import `.srpack` / `.json`**: Drag-and-drop upload into the same Guided Install Wizard (subject to `allow_unsigned_pack_uploads` policy, defaulting to admin/install-gated upload with SHA-256 manifest verification).
  - **Export as Pack**: Multi-select existing authored `DeclarativeCheck`s, `StatefulAlertRule`s/`EventRule`s/`ZenRule`s, and `Dashboard`s -> enter pack metadata -> run `SecretFreeValidator` -> download `.srpack` OR **Push to GitOps Repository** (creating a PR or commit directly from `web-ng`).

### Decision 7: Packaging & Signing Tooling in `@carverauto/serviceradar-cli` (`js/cli`)

Following the architectural rule from `add-third-party-plugin-repositories` ("publishing tooling lives in the NPM CLI, not in the SDKs"), we add a `pack` command group to `@carverauto/serviceradar-cli` (`js/cli/src/pack/`) and expose `serviceradar` alongside `serviceradar-cli` in `package.json#bin`:
- `serviceradar pack validate <dir-or-srpack>`: Offline validation of `manifest.json` schema, SemVer, SVG sanitization, `checks/*.json` (`DeclarativeCheck` schema), `rules/*.json`, `dashboards/*.json` (grid non-overlap and field binding rules), `manifest.files` SHA-256 digests, and `SecretFreeValidator` (exits non-zero if any secret-like field or unlisted file exists).
- `serviceradar pack build <dir> --out <slug>.srpack`: Recomputes `manifest.files` SHA-256 digests, runs `validate`, and writes a byte-for-byte deterministic `tar.zst` `.srpack` archive.
- `serviceradar pack sign --bundle <slug>.srpack --out <slug>.srpack.sig`: Signs canonical JSON `{"content_hash": "<sha256>", "manifest": <canonical-manifest>}` with an ed25519 private key (`PACK_UPLOAD_SIGNING_PRIVATE_KEY[_FILE]` or `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY[_FILE]`, plus `keygen` support), producing an `UploadSignature` JSON document verified identically by `ServiceRadarWebNG.Plugins.UploadSignature` and `build/wasm_plugins/upload_signature_tool.go`.
- `serviceradar pack index <packs-dir> --out serviceradar-pack-index.json [--github-repo <org/repo> --release-tag <tag> | --base-url <url>]`: Analogous to `timeplus-apps/registry/build.py`, scans built `.srpack` + `.srpack.sig` pairs and emits `serviceradar-pack-index.json` with embedded manifests, SHA-256 digests, resource counts, download URLs, and signature URLs for GitHub/Gitea Releases or local HTTP hosting.

## Risks / Trade-offs

- **Archive bomb or path traversal in uploaded/fetched `.srpack` bundles** -> Mitigated by strict `PackArchive` streaming limits (25 MB compressed, 64 MB uncompressed, max 256 files, reject `..`, absolute paths, symlinks, hardlinks) and mandatory `manifest.files` SHA-256 digest matching before any DB write.
- **Stored XSS through pack `icon` SVG or `README.md` / `assets/*.svg`** -> Mitigated by server-side allowlist SVG sanitization (rejecting `<script>`, `<foreignObject>`, event handlers, and external URLs) and strict HTML sanitization + `rel="noopener noreferrer"` on rendered Markdown.
- **Accidental secret exfiltration when pushing packs to Git** -> Mitigated by two independent gates: structural allowlist projection (which drops credential IDs and emits abstract `credential_slots`) followed by `SecretFreeValidator` key/token scanning before any blob or archive is created, plus OCSF audit logging of every export and GitOps push.
- **GitOps concurrent branch updates (`non-fast-forward` race)** -> Mitigated by defaulting `push_strategy` to `:pull_request` (which creates a fresh branch and PR/MR) and passing expected parent commit SHA on `:direct_commit` so concurrent upstream commits fail cleanly with a structured conflict message rather than force-pushing (`force: false` always).
- **Wasm capability escalation via pack installation** -> Mitigated by refusing to auto-approve staged Wasm plugins during pack install; `plugin_dependencies` only bind already-approved `PluginPackage` versions or direct administrators to the existing staged capability review queue.

## Migration Plan

1. **Additive schema migration (`mix ash.codegen`)**:
   - Create `platform.catalog_repositories` and seed `https://github.com/carverauto/serviceradar-apps` (`mode: :release_catalog`, `builtin: true`, `is_default: true`) idempotently keyed on `(mode, repo_url, branch, base_path)`.
   - Create `platform.installed_solution_packs`.
   - Add nullable `pack_id`, `pack_version`, `parameter_overrides` (and `managed`, `template_fingerprint` where not already present on `EventRule`, `ZenRule`, and `Dashboard`, matching `StatefulAlertRule` and `DeclarativeCheck`) with indexes on `pack_id`.
2. **Seed Built-in Pack #1**:
   - Ship `priv/solution_packs/storage-and-nvr-health/` in `serviceradar_core` so every deployment has Built-in Pack #1 available offline in the Catalog Gallery on boot without requiring external network egress.
3. **Rollback**:
   - Detaching or uninstalling a pack leaves standalone checks/rules/dashboards valid (`managed: false`) or cleanly removes pack-owned rows; dropping `installed_solution_packs` and `catalog_repositories` does not affect standalone observability or plugin repositories.

## Open Questions

- Should recurring background sync (`CatalogSyncWorker`) for `:gitops_tree` repositories default to **fetch & notify ("Update Available" badge in Catalog UI)** rather than unattended auto-apply, reserving unattended auto-apply for an explicit per-repository `auto_reconcile: true` toggle? This design defaults `:gitops_tree` sync to **fetch & notify + 1-click dry-run apply** so production changes always have human confirmation unless the operator opts into `auto_reconcile: true`.
