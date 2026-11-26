## ADDED Requirements

### Requirement: Solution Pack Vantage ML pipeline, signal schema, and worker dependency bundling
The system SHALL extend the Solution Pack manifest contract (`pack_format_version: 2`, while remaining backward-compatible with `pack_format_version: 1`) to declare optional `vantage_pipelines/*.json` definitions, companion `signal_schemas/*.json` payload and display contracts, and `worker_dependencies` (`capability`, `min_protocol_version`, `optional`, `fallback_runner`), validating all files against `manifest.files` SHA-256 digests and `SecretFreeValidator` and reconciling them with managed provenance (`pack_id`, `pack_version`, `managed`, `template_fingerprint`, `parameter_overrides`).

#### Scenario: Installing a Vantage Solution Pack reconciles pipelines, signal schemas, and worker readiness
- **GIVEN** a valid `pack_format_version: 2` `.srpack` archive for `io.serviceradar.vantage-alpr` containing `vantage_pipelines/alpr-vehicle-plate.json`, `signal_schemas/alpr_plate_read.schema.json`, `signal_schemas/alpr_plate_read.display.json`, and `worker_dependencies` declaring `vantage.alpr.v1` (`optional: true`, `fallback_runner: "camera_vlm"`)
- **WHEN** an authorized operator completes guided installation in the Catalog Gallery
- **THEN** `DependencyChecker` SHALL report whether a healthy worker providing `vantage.alpr.v1` is online (or confirm Ramp 1 `camera_vlm` fallback readiness)
- **AND** `Reconciler` SHALL atomically create the managed `VantagePipeline`, register the `signal_schema` and display contract, and reconcile companion checks, rules, and dashboards stamped with `pack_id`, `pack_version`, `managed: true`, and `template_fingerprint`

#### Scenario: Required Vantage worker dependency missing blocks active pipeline activation
- **GIVEN** a Solution Pack declaring a `worker_dependencies` entry with `optional: false` and no `fallback_runner`
- **WHEN** an operator previews or attempts active installation while zero healthy workers advertise that capability
- **THEN** `DependencyChecker` SHALL surface the missing worker capability clearly in the guided install wizard and block active pipeline activation until a compatible worker is online or the operator installs the pipeline in paused state

### Requirement: Solution Pack Dashboard SDK browser-module bundling and governed approval
The system SHALL allow `pack_format_version: 2` Solution Packs to bundle `dashboard-browser-module-v1` packages under `dashboard_packages/<slug>/` (`manifest.json` + `renderer.js`, covered by `manifest.files` SHA-256 digests and bounded by an `8 MiB` per-renderer size cap and `32 MiB` compressed / `96 MiB` uncompressed archive limit) or reference an already-published `dashboard_id@version` via `dashboard_package_dependencies`, and SHALL enforce explicit admin approval and RBAC gating before enabling any bundled JavaScript renderer or binding a `DashboardInstance` route slug.

#### Scenario: Bundled Dashboard SDK browser module is verified, staged, and enabled only with dashboard-manage RBAC
- **GIVEN** a signed `pack_format_version: 2` `.srpack` containing `dashboard_packages/alpr-console/manifest.json` and `dashboard_packages/alpr-console/renderer.js` whose SHA-256 matches both the dashboard manifest and `manifest.files`
- **WHEN** an operator installs the pack
- **THEN** `Reconciler` SHALL import the bundled package through `ServiceRadar.Dashboards.PackageImport` verifying renderer SHA-256 and `version_already_published` immutability
- **AND** if the installer holds both `catalog.packs.install` and `dashboards.packages.manage` (or `cli.dashboard.publish`) and explicitly approves activation, the system SHALL enable the `DashboardPackage` and bind its managed `DashboardInstance` route slug; otherwise it SHALL leave the `DashboardPackage` in `:staged` status for an authorized dashboard administrator to approve

#### Scenario: Bundled renderer hash mismatch or conflicting enabled version fails closed
- **GIVEN** a `.srpack` whose `dashboard_packages/alpr-console/renderer.js` bytes do not match either `manifest.files` or `dashboard_packages/alpr-console/manifest.json`, OR whose `dashboard_id@version` already exists as an enabled `DashboardPackage` with a different `content_hash`
- **WHEN** pack validation or installation runs
- **THEN** the operation SHALL fail closed before modifying CNPG records or serving updated renderer bytes

#### Scenario: Uninstalling a Solution Pack cleanly detaches or disables managed Vantage pipelines and dashboard bindings
- **WHEN** an authorized operator uninstalls a Solution Pack that installed a managed `VantagePipeline` and a pack-bound `DashboardInstance`
- **THEN** the system SHALL disable or remove the managed `VantagePipeline` (stopping new job dispatch immediately) and disable or detach the pack-managed `DashboardInstance` binding while preserving any operator-detached (`managed: false`) resources
