## ADDED Requirements

### Requirement: Declarative Check Visual Pipeline Builder and Management UI
The `web-ng` UI SHALL provide `/settings/declarative-checks` and `/settings/declarative-checks/:slug` views mounting a React 19 visual DAG builder (`DeclarativeCheckBuilderCanvas.jsx`) built with Palantir Blueprint v6 chrome (`@blueprintjs/core`, `@blueprintjs/icons`, `@blueprintjs/select`), `@xyflow/react` drag-and-drop nodes and wires, `elkjs` layered auto-layout, a right-hand Blueprint property inspector drawer, and a `Monaco` canonical JSON tab.

Blueprint v6 styles and overlays MUST be strictly scoped inside a `.sr-bp6-scope` container with `.bp6-dark` theme synchronization and a scoped `portalContainer` so Blueprint global CSS resets never leak onto Tailwind v4 or daisyUI chrome outside the canvas.

#### Scenario: Blueprint v6 chrome and portals stay isolated from Tailwind v4 and daisyUI
- **GIVEN** an authenticated operator opens `/settings/declarative-checks/checkout-api-health` in dark or light mode
- **WHEN** the Blueprint v6 property inspector drawer, node select menu, or popover renders
- **THEN** `.sr-bp6-scope` SHALL synchronize `.bp6-dark` with the active ServiceRadar theme and mount all Blueprint portals inside the scoped `portalContainer`
- **AND** navigation bars, daisyUI buttons, and Tailwind v4 typography outside `.sr-bp6-scope` SHALL remain unaffected by Blueprint global CSS rules

#### Scenario: Two-way live sync between visual DAG canvas and Monaco JSON tab
- **GIVEN** an operator editing a declarative check in `DeclarativeCheckBuilderCanvas`
- **WHEN** the operator drags a `threshold_assert` node onto the `@xyflow/react` canvas and wires it to `alert_output`, OR edits threshold JSON in the `Monaco` tab
- **THEN** canvas edits SHALL immediately update the deterministic canonical JSON in `Monaco`
- **AND** valid `Monaco` JSON edits SHALL update the `@xyflow/react` graph and run `elkjs` auto-layout for any newly added nodes lacking `ui_layout` coordinates

#### Scenario: Starter graph templates populate valid check pipelines in one click
- **GIVEN** an operator creating a new declarative check
- **WHEN** the operator clicks one of the four starter templates (`"HTTP JSON API Check"`, `"SRQL Posture Check"`, `"Multi-Step Synthetic Journey"`, or `"Multi-Vantage Composite Check"`)
- **THEN** the canvas and `Monaco` editor SHALL populate with a complete, schema-valid `schema_version: 1` DAG laid out via `elkjs`

### Requirement: Interactive Declarative Check Test Run and Redacted Node Trace
The declarative check builder UI SHALL provide an interactive **Test Run** action (gated on `declarative_checks.evaluate`) that executes the authored DAG against a selected target before saving and overlays per-node resolved inputs, extracted values, execution timings, and the final verdict directly on the canvas without mutating `ServiceState` or triggering alerts.

#### Scenario: Test Run renders node-by-node execution trace with secrets redacted
- **GIVEN** an operator editing an unsaved `http_journey` check bound to a `credential_slot` via `SecretBroker`
- **WHEN** the operator clicks **Test Run**
- **THEN** the builder SHALL display each node's status, `duration_ms` (including `httptrace` waterfall phases), extracted fields, matched decision row, and final verdict (`healthy` | `degraded` | `down` | `unknown`)
- **AND** any brokered credential header or secret value SHALL appear strictly as `"[REDACTED]"` in the trace inspector

### Requirement: Declarative Check UI Import, Export, and Legacy Clone Actions
The `web-ng` UI SHALL allow operators to import and export secret-free canonical check JSON documents from `/settings/declarative-checks`, bind abstract `credential_slots` to CNPG credentials/rules, and clone legacy `ServiceCheck` or `CompositeCheck` records into draft declarative checks in one click.

#### Scenario: Operator clones a legacy ServiceCheck or CompositeCheck into the visual builder
- **GIVEN** an operator viewing an existing `ServiceCheck` or `CompositeCheck` in `web-ng`
- **WHEN** the operator clicks `"Clone as Declarative Check"`
- **THEN** the UI SHALL create a `state: "draft"` `DeclarativeCheck` via `LegacyImporter` and open it in `/settings/declarative-checks/:slug` for **Test Run** preview without disabling or altering the legacy check
