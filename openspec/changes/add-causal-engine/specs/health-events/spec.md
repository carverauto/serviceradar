# health-events Specification

## ADDED Requirements

### Requirement: Controlled Health-State Vocabulary

The system SHALL define a single, severity-ordered controlled vocabulary (Gap C) for the `health_events.new_state` field that applies uniformly across all monitored entities (devices, services, structured device components, and BGP peers). The existing atom enum on `health_events.new_state` — `healthy`, `degraded`, `offline`, `connected`, `disconnected`, `active`, `failing`, `recovering`, `maintenance` — SHALL be reconciled into this vocabulary and EXTENDED to add three new states: `degrading`, `reduced-redundancy`, and `failed`.

The vocabulary SHALL be ordered by severity from least to most severe as follows: `healthy` (also covering legacy `connected` and `active`) < `recovering` < `maintenance` < `degrading` < `degraded` < `reduced-redundancy` < `failing` < `failed` (also covering legacy `offline` and `disconnected`). Severity ordering SHALL be total so that any two states are comparable, enabling consumers to compute worst-of rollups across an entity and its components.

Legacy values SHALL retain their stored representation for backward compatibility, but each SHALL map to a canonical vocabulary entry: `connected` and `active` map to `healthy`; `offline` and `disconnected` map to `failed`. New transitions SHOULD prefer the canonical vocabulary entries over the legacy aliases.

The causal-engine OUTPUT vocabulary (the health-state values it emits via causal prediction signals) SHALL align with this same controlled vocabulary, so that a verdict produced by the reasoner uses identical state names and the same severity ordering as the persisted `health_events.new_state`, closing the producer/consumer loop. See `causal-prediction-signals` for how engine verdicts are normalized and re-enter the automation loop, and `device-components` for how component-level states roll up into the parent entity state under this same vocabulary.

#### Scenario: Extended vocabulary accepts a degrading transition

- **GIVEN** the controlled health-state vocabulary is in effect
- **WHEN** a device begins trending toward failure but is not yet degraded
- **THEN** a `HealthEvent` record SHALL be inserted with `new_state` set to `degrading`
- **AND** `degrading` SHALL be ordered as less severe than `degraded` and more severe than `maintenance`

#### Scenario: Reduced-redundancy state for partial component loss

- **GIVEN** a device has redundant structured components (for example dual power supplies or bonded uplinks)
- **WHEN** one redundant component fails while the entity remains operational
- **THEN** a `HealthEvent` record SHALL be inserted with `new_state` set to `reduced-redundancy`
- **AND** the entity overall SHALL NOT be reported as `failed` or `failing`
- **AND** `reduced-redundancy` SHALL be ordered as more severe than `degraded` and less severe than `failing`
- **AND** the component-level states feeding this rollup SHALL use the same vocabulary as defined in `device-components`

#### Scenario: Legacy value maps to canonical entry

- **GIVEN** an existing transition stored the legacy value `offline`
- **WHEN** a consumer reads the health state and resolves it against the controlled vocabulary
- **THEN** `offline` SHALL resolve to the canonical entry `failed`
- **AND** `connected` and `active` SHALL resolve to the canonical entry `healthy`
- **AND** the stored legacy representation SHALL remain unchanged for backward compatibility

#### Scenario: Causal-engine output aligns with the persisted vocabulary

- **GIVEN** the causal-engine reasoner produces a verdict that an entity has transitioned to `failing`
- **WHEN** the verdict is emitted via `causal-prediction-signals`
- **THEN** the emitted health-state value SHALL be exactly `failing` as defined in this controlled vocabulary
- **AND** the emitted value SHALL carry the same total severity ordering as `health_events.new_state`
- **AND** a downstream consumer SHALL be able to compare an engine-emitted state against a persisted `HealthEvent` state without remapping

#### Scenario: Vocabulary applies uniformly across entity classes

- **GIVEN** the controlled health-state vocabulary is the single source of truth for health states
- **WHEN** a service, a BGP peer, and a structured device component each transition health states
- **THEN** each SHALL use state names drawn only from the controlled vocabulary
- **AND** no entity class SHALL introduce a state name outside the vocabulary
