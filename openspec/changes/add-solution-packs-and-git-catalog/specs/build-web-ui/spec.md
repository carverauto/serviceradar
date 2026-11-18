## ADDED Requirements

### Requirement: Solution Packs Catalog Gallery LiveView
The web UI MUST provide a Solution Packs Catalog Gallery LiveView (`/catalog`) featuring instant search, category filter pills (`Storage & NVR`, `Network & WAN`, `Synthetic HTTP`, `Security & Posture`, `Infrastructure`), source filtering, `Available` vs `Installed` vs `Updates Available` tabs, sanitized inline SVG icons, `"What's inside"` resource count badges (`N checks * M alert rules * K dashboards`), rendered `README.md` documentation, interactive read-only check DAG and Monaco JSON previews, and 1-click `.srpack` / `.json` browser import and secret-free export.

#### Scenario: Operator filters catalog by category and inspects pack contents before installing
- **GIVEN** the operator opens `/catalog`
- **WHEN** the operator selects the `Storage & NVR` category pill and clicks `Storage Entitlements & NVR Recording Health`
- **THEN** the gallery filters matching packs without a full page reload
- **AND** the detail view displays the sanitized SVG icon, `"4 checks * 2 alert rules * 1 dashboard"` badge, rendered `README.md`, typed `config` inputs, and read-only `@xyflow/react` DAG + Monaco JSON previews for each bundled resource

#### Scenario: Malicious SVG or Markdown in a pack is sanitized before rendering
- **GIVEN** an imported pack whose `icon` SVG or `README.md` contains `<script>`, `<foreignObject>`, inline `onload` handlers, or external `xlink:href` references
- **WHEN** the Catalog Gallery renders the card and detail view
- **THEN** executable elements, event attributes, and external SVG references are stripped server-side prior to rendering

### Requirement: Guided Solution Pack Install and Upgrade Wizard UI
The web UI MUST present a guided multi-step wizard when installing or upgrading a Solution Pack, collecting typed `config` inputs, binding `credential_slots` to unified CNPG credentials (with an inline link to create missing credentials in Settings -> Credentials), displaying `plugin_dependencies` readiness, and rendering a side-by-side Monaco structural diff and conflict resolution selector during pack upgrades (`0.1.0 -> 0.2.0`).

#### Scenario: Operator binds credential slot and installs pack through wizard
- **GIVEN** an operator clicks `Install` on a pack declaring `config` parameters and one `credential_slot`
- **WHEN** the wizard renders
- **THEN** step 1 validates typed `config` inputs against `min`/`max`/`enum` constraints, step 2 lists compatible `NetworkCredentialRule` and `NetworkCredentialSecret` records alongside an inline `Create Credential` link, step 3 previews every check, rule (`enabled` vs `paused`), and dashboard to be created, and step 4 applies installation and links to the installed resources

#### Scenario: Upgrade wizard shows side-by-side diff and protects customized resources
- **GIVEN** an installed pack at `0.1.0` where `0.2.0` is available and one check was structurally customized by an operator
- **WHEN** the operator opens `Upgrade to 0.2.0`
- **THEN** the wizard displays preserved `parameter_overrides`, renders a side-by-side Monaco diff for the diverged check, and defaults that check to `Keep Customized (Detach managed: false)` unless the operator explicitly chooses `Reset to Upstream 0.2.0`

### Requirement: Managed Resource Provenance Banner and Detach Prompt in Editors
The Declarative Check canvas builder, Observability Rule editors, and Authored Dashboard builder MUST display pack provenance (`pack_id`, `pack_version`, `managed` badge) on pack-managed records, save parameter/threshold edits into `parameter_overrides` while preserving `managed: true`, and prompt for explicit confirmation before applying structural edits that detach the record (`managed: false`).

#### Scenario: Structural DAG edit on a managed check prompts to fork
- **GIVEN** an operator opens a `managed: true` `DeclarativeCheck` installed by `io.serviceradar.storage-and-nvr-health` in the visual pipeline canvas
- **WHEN** the operator adds or deletes a node or edge and clicks `Save`
- **THEN** the UI explains that structural changes diverge from the pack template and prompts the operator to confirm `Save as Detached Copy (managed: false)` or `Cancel`
- **AND** editing a declared threshold or schedule parameter saves into `parameter_overrides` without detaching

### Requirement: Catalog Repository and GitOps Sync Controls in Web UI
The web UI MUST provide RBAC-gated controls for managing `:release_catalog` and `:gitops_tree` `CatalogRepository` records, pushing secret-free Solution Pack trees to connected Git repositories (as a pull/merge request or direct commit), and previewing/applying GitOps pull promotions across environments.

#### Scenario: Operator pushes pack to private GitOps repository as a pull request from web-ng
- **GIVEN** an operator holding `catalog.gitops.sync` and a configured `:gitops_tree` repository
- **WHEN** the operator selects resources or an installed pack, clicks `Push to Git`, previews the secret-free file tree, and submits in `Pull Request` mode
- **THEN** the UI displays the created branch and pull/merge request URL without exposing the repository PAT

#### Scenario: Users without repository management permission cannot add or edit catalog sources
- **GIVEN** a user holding `catalog.view` without `catalog.repositories.manage`
- **WHEN** the user views the Catalog Gallery source selector
- **THEN** enabled catalog sources can be browsed, while `Add Repository`, `Edit`, and `Remove` controls are hidden
