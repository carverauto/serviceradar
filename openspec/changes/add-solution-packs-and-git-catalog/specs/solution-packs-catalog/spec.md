## ADDED Requirements

### Requirement: Solution Pack Manifest and Archive Contract
The system SHALL define a deterministic Solution Pack format (`pack_format_version: 1`) with a lossless 1:1 mapping between a Git directory tree and a `.srpack` archive.
Each pack MUST contain a root `manifest.json` declaring reverse-DNS `id`, `slug`, `name`, SemVer `version`, `author`, `categories`, sanitized inline/data-URI SVG `icon`, `description`, `min_serviceradar_version`, typed `config` parameter descriptors (`key`, `type`, `default`, `min`, `max`, `enum`, `required`, `description`), abstract `credential_slots` (`slot`, `provider`, `role`, `purpose`, `required`), optional `plugin_dependencies`, explicit `resources` (`checks/*.json`, `rules/*.json`, `dashboards/*.json`), and a lowercase SHA-256 `files` digest map covering every non-manifest file in the pack.

#### Scenario: Valid solution pack directory and archive round-trip deterministically
- **GIVEN** a valid `pack_format_version: 1` pack directory containing `manifest.json`, `README.md`, `checks/*.json`, `rules/*.json`, and `dashboards/*.json`
- **WHEN** the pack is built into a `.srpack` archive twice on separate hosts
- **THEN** both `.srpack` archives produce identical SHA-256 digests with sorted entries, normalized permissions, and epoch timestamps
- **AND** extracting the `.srpack` archive reproduces the exact directory files matching `manifest.files`

#### Scenario: Unsupported pack format version or digest mismatch is rejected
- **GIVEN** a pack whose `pack_format_version` is unrecognized or whose member file bytes do not match `manifest.files`
- **WHEN** the pack is validated or imported
- **THEN** the system rejects the pack with an error naming the unsupported version or mismatched file path
- **AND** no checks, rules, or dashboards are created or modified

#### Scenario: Unlisted files and archive traversal paths are rejected
- **GIVEN** a `.srpack` or `.zip` upload containing `../` path segments, symlinks, or a file under `checks/`, `rules/`, `dashboards/`, or `assets/` omitted from `manifest.files`
- **WHEN** the archive is parsed
- **THEN** extraction fails closed before writing to the database

#### Scenario: Rule templates honor paused install state
- **GIVEN** a pack rule entry in `manifest.json` declaring `install_state: "paused"` for a `StatefulAlertRule`, `EventRule`, or `ZenRule`
- **WHEN** the pack is installed for the first time
- **THEN** the rule record is created with `enabled: false`
- **AND** subsequent pack upgrades do not flip `enabled` to `true` without operator action

### Requirement: Secret-Free Pack Export and Credential Slot Indirection
The system MUST guarantee that Solution Packs, browser exports, and GitOps pushes never contain plaintext secrets, ciphertext payloads, personal access tokens, or instance-local credential UUIDs, and MUST represent all external authentication through abstract `credential_slots`.

#### Scenario: Exporting live resources replaces credential bindings with abstract credential slots
- **GIVEN** an authored `DeclarativeCheck`, companion alert rules, and an authored dashboard where the check is bound locally to a `NetworkCredentialSecret` (`00000000-0000-4000-8000-000000000010`) or `NetworkCredentialRule`
- **WHEN** an authorized operator exports those resources as a Solution Pack or pushes them to a GitOps repository
- **THEN** the exported `manifest.json` and `checks/*.json` contain only abstract `credential_slots` (`slot`, `provider`, `role`, `purpose`, `required`)
- **AND** database UUIDs, `credential_secret_id`, `credential_rule_id`, and `encrypted_secret_payload` fields are absent from every exported file

#### Scenario: Pre-flight validator rejects secret-bearing fields or token literals
- **GIVEN** a pack directory or export payload containing a forbidden secret key (such as `password`, `secret_payload`, `private_key`, or `community_string`) or a literal token pattern (such as `ghp_`, `github_pat_`, `glpat-`, or PEM private key material)
- **WHEN** pack validation, export, or GitOps push runs
- **THEN** the operation fails closed with a validation error identifying the offending file and JSON path
- **AND** no `.srpack` archive, download response, or Git API request is emitted

### Requirement: Guided Solution Pack Installation and Dependency Verification
The system SHALL install Solution Packs through a transactional guided installation workflow that validates typed `config` values, binds required `credential_slots` to CNPG unified credentials (`platform.network_credential_secrets` or `platform.network_credential_rules`), verifies optional Wasm `plugin_dependencies`, and records `platform.installed_solution_packs`.

#### Scenario: Guided installation binds parameters and credentials and materializes resources
- **GIVEN** a valid Solution Pack declaring typed `config` parameters and one required `credential_slot`
- **WHEN** an authorized operator supplies valid parameter values, binds the `credential_slot` to a compatible `NetworkCredentialRule`, and confirms installation
- **THEN** the system creates the pack's `DeclarativeCheck`, rule, and authored `Dashboard` records stamped with `pack_id`, `pack_version`, `managed: true`, `template_fingerprint`, and `parameter_overrides`
- **AND** records the installation in `platform.installed_solution_packs`

#### Scenario: Missing required credential binding blocks activation
- **GIVEN** a Solution Pack with a `credential_slot` marked `required: true`
- **WHEN** an operator attempts to complete active installation without binding a `NetworkCredentialSecret` or `NetworkCredentialRule` to that slot
- **THEN** the installation is refused with a field error naming the unbound `slot`

### Requirement: Managed Pack Provenance, Parameter Overrides, and Safe Upgrades
The system SHALL stamp pack-installed checks, rules, and authored dashboards with `pack_id`, `pack_version`, `managed`, `template_fingerprint`, and `parameter_overrides`, and SHALL reconcile managed upgrades (`0.1.0 -> 0.2.0`) while preserving operator `parameter_overrides` and refusing to silently overwrite structurally diverged or detached resources.

#### Scenario: Upgrading an unmodified managed pack preserves operator parameter overrides
- **GIVEN** pack `io.serviceradar.storage-and-nvr-health` installed at `0.1.0` where the operator customized `utilization_warn_pct` to `80` in `parameter_overrides` without modifying check DAG structure
- **WHEN** the operator upgrades the pack to `0.2.0` containing a new check node and updated dashboard layout
- **THEN** the system reconciles the check DAG and dashboard to the `0.2.0` template, updates `pack_version` to `"0.2.0"`, and recomputes `template_fingerprint`
- **AND** preserves `utilization_warn_pct: 80` in `parameter_overrides` alongside existing `credential_slots` bindings in `platform.installed_solution_pack_credential_bindings` and `platform.declarative_check_credential_bindings`

#### Scenario: Structurally diverged or detached resources are protected during upgrade
- **GIVEN** a pack-installed check or dashboard whose structural fields were customized (`template_fingerprint` mismatch) or explicitly detached (`managed: false`)
- **WHEN** the pack is upgraded to `0.2.0`
- **THEN** the reconciler does not overwrite the diverged or detached resource unless the operator explicitly selects reset-to-upstream for that resource
- **AND** the operator's custom DAG or panel query remains intact

### Requirement: Signed Release Catalog Repositories
The system MUST persist Solution Pack catalog sources in `platform.catalog_repositories`, seed the official `carverauto/serviceradar-apps` release catalog as an immutable `builtin: true` record, fetch all external catalog indexes and `.srpack` assets through `ServiceRadar.HTTP.EgressClient`, and verify every `:release_catalog` bundle against that repository's ed25519 `UploadSignature` public key without requiring public Sigstore Rekor entries.

#### Scenario: Official release catalog is seeded and immutable except enablement
- **GIVEN** a migrated ServiceRadar deployment
- **WHEN** catalog repositories are listed
- **THEN** `https://github.com/carverauto/serviceradar-apps` is present with `mode: :release_catalog`, `builtin: true`, and `is_default: true`
- **AND** attempts to edit its URL or signing keys or destroy it are rejected, while enabling and disabling it are permitted

#### Scenario: Release catalog verifies per-repository ed25519 signature and isolates trust
- **GIVEN** release catalog repositories A and B configured with distinct ed25519 public keys
- **WHEN** a `.srpack` bundle signed by repository A's key is served from repository B
- **THEN** import through repository B fails with `:invalid_signature` before archive extraction

#### Scenario: Private release catalog authenticates with PAT and strips auth on redirect
- **GIVEN** a private GitHub `:release_catalog` repository referencing an `:api_token` `NetworkCredentialSecret`
- **WHEN** `ReleaseCatalogClient` downloads a `.srpack` release asset through `ServiceRadar.HTTP.EgressClient` and follows a `302` redirect to a pre-signed asset host
- **THEN** the GitHub API request authenticates with the PAT and the redirected request carries no `Authorization` header

### Requirement: Two-Way Private Git Tree Synchronization
The system MUST support `:gitops_tree` catalog repositories for GitHub, GitLab, and Gitea/Forgejo over HTTPS Git Data REST APIs through `ServiceRadar.HTTP.EgressClient` without invoking a host `git` binary or writing SSH keys to pod filesystems, supporting both secret-free push (`:pull_request` or `:direct_commit`) and dry-run pull promotion across environments (`dev -> staging -> prod`).

#### Scenario: Operator pushes authored pack tree to private Git repository via pull request
- **GIVEN** a `:gitops_tree` `CatalogRepository` configured with `push_strategy: :pull_request`, `branch: "main"`, `base_path: "packs"`, and a PAT `credential_secret_id` in `platform.network_credential_secrets`
- **WHEN** an authorized operator pushes pack `wan-edge-sla` (`0.1.0`)
- **THEN** the system validates the file tree through `SecretFreeValidator`, creates Git blobs, tree, commit, branch, and pull/merge request under `packs/wan-edge-sla/` via HTTPS REST calls over `ServiceRadar.HTTP.EgressClient`
- **AND** never executes a host `git` subprocess or writes credential material to disk

#### Scenario: Staging or production pulls pack tree from Git branch with dry-run diff preview
- **GIVEN** a `:gitops_tree` repository containing updated `packs/wan-edge-sla/` (`0.2.0`) on branch `main`
- **WHEN** an operator in `staging` or `prod` runs a pull preview and then applies the sync
- **THEN** the preview lists every check, rule, and dashboard create/upgrade/diverged action prior to writing
- **AND** applying the sync reconciles managed resources and records `source_commit_sha` on `platform.installed_solution_packs`

#### Scenario: Direct commit push fails closed on concurrent upstream branch modification
- **GIVEN** a `:gitops_tree` repository configured with `push_strategy: :direct_commit` whose remote branch HEAD advanced after the base tree was read
- **WHEN** the commit ref update is submitted
- **THEN** the push fails without force-pushing and reports the upstream ref conflict to the operator

### Requirement: Solution Pack CLI Build, Validation, Signing, and Indexing
The `@carverauto/serviceradar-cli` tool MUST provide `serviceradar pack validate`, `serviceradar pack build`, `serviceradar pack sign`, and `serviceradar pack index` commands that enforce schema and secret-free validation, emit deterministic `.srpack` archives, generate canonical-JSON ed25519 `UploadSignature` files compatible with `ServiceRadarWebNG.Plugins.UploadSignature`, and compile `serviceradar-pack-index.json` release catalogs.

#### Scenario: CLI builds, signs, and indexes a solution pack verified by ServiceRadar
- **GIVEN** a valid pack directory `packs/storage-and-nvr-health` and an ed25519 signing keypair
- **WHEN** a publisher runs `serviceradar pack validate`, `serviceradar pack build`, `serviceradar pack sign`, and `serviceradar pack index`
- **THEN** the resulting `.srpack`, `.srpack.sig`, and `serviceradar-pack-index.json` pass `ServiceRadarWebNG.Plugins.UploadSignature.verify/4` byte-for-byte without modification

### Requirement: Solution Pack Catalog Authorization, Credential Usage, and Audit Trail
The system MUST enforce dedicated RBAC permissions (`catalog.repositories.manage`, `catalog.packs.install`, `catalog.packs.export`, `catalog.gitops.sync`) at both the UI and Ash policy layers, MUST register all pack and repository `credential_secret_id` references in `ServiceRadar.Credentials.CredentialUsage` and `GuardCredentialDestroy`, and MUST write redacted OCSF audit events for repository changes, pack installs/upgrades/uninstalls, exports, and GitOps syncs.

#### Scenario: In-use catalog or pack credential cannot be deleted
- **GIVEN** a `NetworkCredentialSecret` referenced by a `CatalogRepository` or an `InstalledSolutionPack` slot binding
- **WHEN** an administrator views the secret's usage or attempts to delete it
- **THEN** `CredentialUsage` lists the referencing catalog repository or installed pack
- **AND** `GuardCredentialDestroy` refuses deletion with `credential_in_use`

#### Scenario: Catalog repository and GitOps operations emit secret-free OCSF audit records
- **GIVEN** an administrator adds a `:gitops_tree` repository and pushes a pack commit
- **WHEN** the actions complete
- **THEN** OCSF audit events are recorded via `ServiceRadar.Events.AuditWriter` with actor, action, `repo_url`, `branch`, `pack_id`, `pack_version`, and commit SHA
- **AND** no PAT or secret value appears in the audit payload

### Requirement: Built-In Storage Entitlements and NVR Recording Health Solution Pack
The system SHALL ship Built-in Pack #1 (`io.serviceradar.storage-and-nvr-health`) in `serviceradar_core` using the canonical `pack_format_version: 1` format, bundling the four Storage Entitlements and NVR Recording Health `DeclarativeCheck` definitions, companion `StatefulAlertRule` templates, and overview authored dashboard.

#### Scenario: Built-in Storage and NVR Health pack is available offline in the catalog
- **GIVEN** a freshly booted ServiceRadar deployment with no internet egress
- **WHEN** an operator browses the Solution Packs catalog
- **THEN** `io.serviceradar.storage-and-nvr-health` appears with its 4 checks (`storage-entitlement-utilization`, `storage-hold-pin-pressure`, `storage-archive-credential-health`, `camera-continuous-recording-silence`), 2 alert rules, and 1 dashboard ready for 1-click guided installation
