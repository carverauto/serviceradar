# ansible-integration — deltas

> Scope note: `add-ansible-integration` (the umbrella change, currently 0/91)
> owns the behavioral requirements (Ansible Controller Registration, AWX
> Inventory as a Plugin-Emitted Discovery Source, AWX WASM Plugin, Run
> lifecycle). This change completes the *deployable slice* — the persistence,
> materialization, and lifecycle mechanics that make inventory sync actually
> run — with distinct requirement names (no collisions with the umbrella).

## ADDED Requirements

### Requirement: Ansible domain schema is migrated
The `Automation.Ansible` domain SHALL have committed database migrations creating all of its resource tables and audit version tables in the `platform` schema, so the controller registry, workers, and client operate against real tables in every environment.

#### Scenario: Controller registry table exists after migration
- **GIVEN** a database migrated to the latest schema
- **WHEN** the Ansible domain is queried
- **THEN** `platform.ansible_controllers` and the remaining Ansible resource tables SHALL exist with their declared columns, identities, and unique indexes
- **AND** registering an `AnsibleController` SHALL persist without a missing-relation error

#### Scenario: Migration applies over an existing baseline
- **GIVEN** a database at the prior release baseline
- **WHEN** the Ansible domain migration runs
- **THEN** it SHALL apply cleanly (no duplicate migration versions, no conflict with existing objects)

### Requirement: AWX inventory-sync assignment is materialized from registered controllers
The system SHALL materialize a scheduled `awx-inventory-sync` plugin assignment from registered `AnsibleController` records, delivering `controller_id`, `base_url`, an agent-resolved credential broker grant, and connection parameters to the controller's agent, so the plugin's required configuration is always satisfied.

#### Scenario: Enabled controller produces a working assignment
- **GIVEN** an enabled `AnsibleController` with a base_url, an `agent_id`, and a credential secret
- **WHEN** controller reconciliation runs
- **THEN** an `awx-inventory-sync` assignment SHALL exist on that agent with `controller_id`, `base_url`, and a credential broker grant
- **AND** the delivered configuration SHALL satisfy the plugin's validation (no "controller_id is required" failure)

#### Scenario: Grant matches the on-demand path and is stable across reconciles
- **GIVEN** an unchanged enabled controller
- **WHEN** reconciliation runs repeatedly
- **THEN** the embedded credential broker grant SHALL be equivalent to the grant minted for on-demand AWX verbs (agent-resolved, Authorization Bearer inject, host/path allow-list scoped to the controller)
- **AND** the assignment configuration SHALL NOT churn on every reconcile for an unchanged controller

#### Scenario: Multiple controllers per agent
- **GIVEN** an agent that reaches more than one enabled controller
- **WHEN** reconciliation runs
- **THEN** every reachable controller SHALL be served by that agent's `awx-inventory-sync` assignment without exceeding the one-enabled-assignment-per-agent-and-plugin constraint

#### Scenario: Disabled or deleted controller retracts its assignment
- **GIVEN** an `awx-inventory-sync` assignment materialized from a controller
- **WHEN** the controller is disabled or deleted
- **THEN** the assignment for that controller SHALL be removed (or updated to drop it) on the next reconcile

### Requirement: Ansible controller lifecycle seeds and retires its workers and assignments
Registering, updating, disabling, or deleting an `AnsibleController` SHALL keep its health worker, catalog-sync worker, and inventory-sync assignment consistent, and enabled controllers SHALL be re-seeded at process startup.

#### Scenario: Registration seeds workers and assignment
- **WHEN** an `AnsibleController` is created or enabled
- **THEN** its health-check and catalog-sync workers SHALL be scheduled
- **AND** its inventory-sync assignment SHALL be materialized without requiring a separate manual action

#### Scenario: Startup re-seeds enabled controllers
- **GIVEN** enabled controllers exist
- **WHEN** the core service starts
- **THEN** their health/catalog workers and inventory-sync assignments SHALL be (re)seeded so scheduling survives restarts

#### Scenario: Disable retires workers and assignment
- **WHEN** an `AnsibleController` is disabled or deleted
- **THEN** its scheduled workers SHALL stop and its inventory-sync assignment SHALL be retracted
