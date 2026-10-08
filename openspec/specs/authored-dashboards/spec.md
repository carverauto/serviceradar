# authored-dashboards Specification

## Purpose
Authored dashboards provide portable declarative JSON definitions for custom and built-in dashboards and panels, enabling import and export across installations, seed-on-startup without overwriting operator modifications, and provenance tracking across first-party, GitHub, and uploaded definitions.

## Requirements

### Requirement: Dashboards are described by a portable declarative definition

The product SHALL describe an authored dashboard and its panels as a portable JSON definition carrying an explicit format version, and SHALL ship its built-in dashboards as definitions rather than as application code.

A definition SHALL fully determine what renders: the dashboard's identity, default time range and variables, and for each panel its title, SRQL query, visual type, data bindings, grid layout and position. Adding or amending a built-in dashboard SHALL NOT require an application code change.

A definition whose `version` the loader does not recognise SHALL be refused with a message naming the file. Silently ignoring it is prohibited, because a definition the loader skips is indistinguishable from one that was never shipped.

#### Scenario: A built-in dashboard ships as data
- **GIVEN** a built-in dashboard is described by a definition file
- **WHEN** the product is installed
- **THEN** the dashboard appears in the dashboard library
- **AND** no application code enumerates its panels

#### Scenario: An unrecognised format version is refused
- **WHEN** a definition declares a `version` the loader does not support
- **THEN** loading it fails with an error naming the file and the version
- **AND** the definition is not partially applied

#### Scenario: A definition missing a panel layout is refused
- **GIVEN** a definition whose panel omits its grid layout
- **WHEN** it is loaded
- **THEN** it is refused
- **AND** the error names the panel, because panels that default to the same grid cell stack and render as one

#### Scenario: A definition with overlapping panels is refused
- **GIVEN** a definition in which two panels occupy the same grid cell
- **WHEN** it is loaded
- **THEN** it is refused, because one panel would be invisible

#### Scenario: A binding naming an unselected field is refused
- **GIVEN** a panel binding a field its own query does not select
- **WHEN** the definition is loaded
- **THEN** it is refused, because such a panel renders empty with no error

### Requirement: Importing a definition never overwrites stored dashboard state

The product SHALL create a dashboard from a definition only when no dashboard with that identity exists, and SHALL NOT write a definition's title, description, time range, panel query, binding or layout over a stored value.

A dashboard record that exists with no panels at all MAY have its panels created, since that is an interrupted creation rather than a configuration produced through the builder.

This constraint is absolute and takes precedence over delivering an improved shipped definition. An import that restores shipped values over operator edits is prohibited: the divergence it creates appears only after a restart, long after the edit appeared to succeed, which is what makes it more damaging than refusing the edit outright. A consequence SHALL be accepted — a later release's improvements do not reach an installation whose copy has been customised.

#### Scenario: An edited query survives re-import
- **GIVEN** an operator narrowed a built-in dashboard panel's query
- **WHEN** the service restarts and definitions are imported again
- **THEN** the panel still carries the operator's query

#### Scenario: An operator-added panel survives re-import
- **GIVEN** an operator added a panel to a built-in dashboard
- **WHEN** definitions are imported again
- **THEN** the added panel remains

#### Scenario: A shipped definition changing does not stomp a customised copy
- **GIVEN** an installation whose copy of a built-in dashboard has been edited
- **WHEN** a later release ships a changed definition for it
- **THEN** the stored dashboard is unchanged
- **AND** the operator's edits are intact

#### Scenario: An incomplete dashboard is completed
- **GIVEN** a dashboard record exists with no panels because creation was interrupted
- **WHEN** definitions are imported again
- **THEN** its panels are created

### Requirement: An authored dashboard can be exported to the definition format

The product SHALL export an existing authored dashboard to the same definition format it imports, so a dashboard assembled in the builder can be saved, reviewed, version-controlled and imported into another installation.

Export SHALL be available to an actor authorized to view that dashboard, under the same authorization the dashboard itself enforces.

Export and import SHALL be inverses over the fields the format defines. Fields outside the format SHALL be stated explicitly so that "equivalent" is defined.

**Dashboard-level exclusions** (not in the exported definition):
- `id`, `dashboard_ref` — database and display identifiers, reassigned on import
- `inserted_at`, `updated_at`, `archived_at` — timestamps
- `owner_id` — ownership; the importing installation applies its own
- `visibility`, `status` — operational state set by the importing installation
- `source_type`, `source_repo_url`, `source_ref`, `source_release_tag`, `source_commit`, `source_path`, `content_hash`, `signature` — import provenance, recorded afresh by the importing installation

**Panel-level exclusions** (not in the exported definition):
- `id`, `dashboard_id` — database identifiers
- `inserted_at`, `updated_at` — timestamps
- `builder_state` — transient UI state, reconstructed from the query
- `field_metadata` — cached display hints, repopulated on load
- `dataset_key` — inferred by the compiler from the query
- `refresh_interval_seconds`, `metadata` — installation-local configuration

**Associated collections excluded entirely:** access grants and report schedules reference principals and schedules that may not exist in an importing installation.

#### Scenario: A builder-made dashboard round-trips
- **GIVEN** a dashboard assembled in the builder with several panels
- **WHEN** it is exported and the definition is imported under a new identity
- **THEN** the imported dashboard carries the same panels, queries, bindings, visual types and layout
- **AND** it renders equivalently

#### Scenario: Export respects dashboard authorization
- **GIVEN** an actor who cannot view a dashboard
- **WHEN** that actor attempts to export it
- **THEN** the export is refused

#### Scenario: Excluded fields are not fabricated on import
- **WHEN** a definition is imported
- **THEN** access grants and report schedules from the exporting installation are absent
- **AND** the importing installation's own ownership applies

### Requirement: Report definitions are importable from a first-party release, a GitHub repository, or an upload

The product SHALL import a report definition from one of three sources, recorded on the dashboard as `source_type`: `first_party` (the OSS repository at a release tag), `github` (a repository the operator nominates), or `upload` (a definition supplied directly). An imported dashboard SHALL carry provenance: the source repository and requested ref where applicable, the release tag and resolved commit where applicable, the definition's repository path, the SHA256 of the definition bytes, and the commit's signature state. Provenance SHALL be written only when the dashboard is created, and SHALL NOT be writable through a dashboard edit.

Every source SHALL pass a definition through the same size limit, decode and validation as a definition shipped with the product, so no source reaches the database under looser rules than another.

A first-party release SHALL publish its reports through an index at `elixir/web-ng/priv/dashboards/index.json`, listing each report's slug, definition path, and whether it is enabled by default. The running build SHALL create its own enabled-by-default reports from the same index at startup, and SHALL treat a shipped definition file the index does not list as an error rather than skipping it.

A `github` import SHALL be refused unless the repository passes the repository-boundary and commit-signature policy that governs a plugin import. A `first_party` import reads a repository fixed by the product rather than nominated by an operator, so those operator policies do not apply to it; its commit signature state SHALL still be recorded.

Import SHALL follow the rule for shipped definitions: a slug that already exists is left exactly as found, whether or not it has been customised, and the operator is told it was kept. A report needs no renderer artifact and SHALL NOT be imported through the dashboard-package path that requires one.

#### Scenario: A first-party release lists its reports
- **GIVEN** a release whose report index lists two reports, one enabled by default
- **WHEN** an operator lists first-party reports for that release tag
- **THEN** both reports are listed with their titles and whether each is enabled by default and already installed

#### Scenario: A customised report survives re-import
- **GIVEN** an imported report whose panel query an operator has edited
- **WHEN** the operator imports the same slug again, from any source
- **THEN** the stored report is unchanged and the operator is told it was kept

#### Scenario: An upload is validated like a fetched definition
- **GIVEN** a definition whose panels overlap in the grid
- **WHEN** it is uploaded
- **THEN** the import is refused with the same message a shipped definition would produce

#### Scenario: An untrusted repository is refused
- **GIVEN** repository-boundary policy that does not include the nominated repository
- **WHEN** an operator imports a report from it
- **THEN** the import is refused and nothing is created

#### Scenario: An unlisted shipped definition is loud
- **GIVEN** a definition file in the shipped directory that the index does not list
- **WHEN** shipped definitions are loaded
- **THEN** loading reports an error naming that file
