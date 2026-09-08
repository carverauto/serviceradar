## ADDED Requirements

### Requirement: Manifest-Driven Add-on Package Seeding
The native add-on package seeded into the control plane SHALL derive its version,
config schema, and capability/requirement metadata from the in-image add-on
manifest (`addon.yaml` + `config.schema.json`), not from a hardcoded version. A
manifest version or schema change SHALL be reflected in the seeded package on the
next control-plane boot.

#### Scenario: Manifest version bump surfaces to operators
- **WHEN** the in-image netprobe manifest version advances (e.g. 0.1.0 to 0.2.0) and matching signed artifacts are configured
- **THEN** the seeder creates and approves the new package version
- **AND** the add-ons UI shows the new version instead of the previous one

#### Scenario: Schema change reaches the operator form
- **WHEN** the in-image config schema changes for an already-seeded add-on version
- **THEN** the seeder updates the seeded package's stored config schema
- **AND** the assignment form renders the updated schema

### Requirement: Unverified Versions Are Staged Not Approved
The seeder SHALL record a package as staged (visible but not assignable), never
approved, when the manifest declares a version for which no matching signed
artifacts are configured, rather than silently retaining a stale prior version.

#### Scenario: Manifest ahead of artifacts
- **WHEN** the manifest version has advanced but no signed artifacts exist for that version
- **THEN** the package is recorded as staged and is not assignable
- **AND** operators can see the version gap instead of a silently frozen package

### Requirement: Native Add-ons Republish On Release
Native add-on artifacts SHALL be (re)published on every release tag so the
published artifacts and the versions surfaced to operators track the released code,
not only manual workflow dispatch.

#### Scenario: Release republishes add-ons
- **WHEN** a `v*` release tag is pushed
- **THEN** the native add-on publish workflow runs and publishes the current add-on artifacts
- **AND** the seeded package can be refreshed to the released version
