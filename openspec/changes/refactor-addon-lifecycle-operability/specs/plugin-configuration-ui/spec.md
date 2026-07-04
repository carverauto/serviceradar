# plugin-configuration-ui — deltas

## ADDED Requirements

### Requirement: Add-on fleet view shows effective state without version noise
The add-on fleet view SHALL present one row per (agent, add-on) showing the effective state — assigned version, running version, and health — and SHALL NOT enumerate historical or unassigned versions as peer rows. Catalog-only inventory entries SHALL NOT appear in the fleet status table.

#### Scenario: One row per agent and add-on
- **GIVEN** an agent with anomaly add-on versions 0.1.19 and 0.1.20 known to the catalog, 0.1.20 assigned
- **WHEN** the fleet view renders
- **THEN** exactly one anomaly row SHALL appear for that agent showing assigned 0.1.20 and the running version
- **AND** version 0.1.19 SHALL be reachable only from the add-on's detail view

#### Scenario: Catalog-only entries are separated
- **GIVEN** an add-on version that exists in the catalog but is assigned to no agent
- **WHEN** the fleet view renders
- **THEN** the entry SHALL appear in a catalog/availability surface, not as an agentless row (no "— (catalog only)" rows in the fleet table)

#### Scenario: Fleet table fits standard viewports
- **GIVEN** a desktop viewport of 1440px or wider
- **WHEN** the fleet view renders
- **THEN** all columns SHALL be visible without horizontal scrolling
- **AND** status badges SHALL never render truncated or clipped text
- **AND** long diagnostic text SHALL be reachable in full via expansion or detail view rather than inline truncation

### Requirement: Drift is rendered as a meaningful comparison
Version drift indicators SHALL present the compared values ("running X, assigned Y") and SHALL NOT render when there is no meaningful comparison (no assignment, or no reported running version).

#### Scenario: Real drift shows both versions
- **GIVEN** an agent running add-on version 0.1.19 with 0.1.20 assigned
- **WHEN** the fleet view renders the row
- **THEN** the drift indicator SHALL show both versions (e.g. "running 0.1.19 → assigned 0.1.20")

#### Scenario: No fabricated drift for unassigned add-ons
- **GIVEN** an agent running an add-on with no assigned version
- **WHEN** the fleet view renders the row
- **THEN** no drift indicator SHALL be shown (never "drift: 0.0.0")
- **AND** the row SHALL state that the add-on is running but unassigned

### Requirement: Idempotent catalog import with progress feedback
Catalog import actions (add-on catalog and WASM plugin catalog alike) SHALL reflect current import state, be idempotent, and provide visible progress and a result summary.

#### Scenario: Import state is visible before acting
- **GIVEN** all catalog entries are already imported
- **WHEN** the catalog page renders
- **THEN** the import action SHALL indicate there is nothing new to import (disabled or relabeled with a count of importable items)

#### Scenario: Import shows progress and outcome
- **GIVEN** importable catalog entries exist
- **WHEN** the operator triggers import
- **THEN** the UI SHALL show an in-progress state while the import runs
- **AND** on completion SHALL summarize what was imported, skipped, and failed

#### Scenario: Plugin catalog parity
- **GIVEN** the WASM plugin catalog page ("Plugins Manager")
- **WHEN** the operator views or triggers Import All
- **THEN** the same state-visibility, idempotence, progress, and summary behavior SHALL apply as for the add-on catalog

### Requirement: Version selection defaults to latest
Assignment and deployment flows SHALL default to the latest approved version of an add-on; selecting an older version SHALL be an explicit drill-in choice on the add-on's detail page; and agents already on the latest version SHALL be visibly marked up to date.

#### Scenario: Latest is the default choice
- **GIVEN** an operator assigning an add-on to agents
- **WHEN** the assignment flow opens
- **THEN** the latest approved version SHALL be preselected
- **AND** older versions SHALL be selectable only from the add-on detail version list

#### Scenario: Up-to-date state is obvious
- **GIVEN** an agent running the latest approved version of an add-on
- **WHEN** the fleet or detail view renders
- **THEN** the row SHALL show an explicit up-to-date indicator instead of a version comparison
