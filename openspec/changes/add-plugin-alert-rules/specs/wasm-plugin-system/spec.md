# wasm-plugin-system

## ADDED Requirements

### Requirement: A plugin package may propose alert rules

A plugin manifest MAY declare an `alert_rules` list. Each entry SHALL be
validated for a non-empty name, a known signal, a non-empty match, and — when
present — a non-empty list of group keys. Unknown keys within an entry SHALL be
rejected.

On approval of the package, each declared rule SHALL be materialized as a
`stateful_alert_rules` row recording the contributing package.

#### Scenario: A declared rule becomes a row on approval
- **GIVEN** a package whose manifest declares an alert rule
- **WHEN** an operator approves the package
- **THEN** a corresponding rule row exists, attributed to that package

#### Scenario: Staged packages contribute nothing
- **GIVEN** a package that has been imported but not approved
- **THEN** no rule rows exist for it

#### Scenario: A manifest with no alert_rules is unaffected
- **WHEN** a manifest omits `alert_rules`
- **THEN** the package imports and approves exactly as before

#### Scenario: A rule matching everything is rejected
- **WHEN** a manifest declares a rule with an empty `match`
- **THEN** manifest validation fails
- **AND** the package is not importable until corrected

### Requirement: A plugin may propose a rule but never activate it

A materialized rule SHALL be created disabled, and `enabled` SHALL NOT be an
accepted manifest key. Activation SHALL require an explicit operator action.

#### Scenario: A manifest cannot arm its own rule
- **WHEN** a manifest declares `enabled: true` on an alert rule
- **THEN** manifest validation fails naming the disallowed key

#### Scenario: Approving a package pages nobody
- **WHEN** a package declaring alert rules is approved
- **THEN** every resulting rule is disabled
- **AND** no alert can fire from them until an operator enables one

### Requirement: Re-syncing a package preserves operator tuning

When a package is re-approved or upgraded, only a rule's definition SHALL be
updated. The operator-owned fields — `enabled`, `threshold`, `window_seconds`,
`bucket_seconds`, `cooldown_seconds`, `renotify_seconds` and `priority` — SHALL
NOT be overwritten.

Those fields MAY be seeded from the manifest when the rule is first created.

#### Scenario: An upgrade does not re-arm a disabled rule
- **GIVEN** an operator disabled a rule a package contributed
- **WHEN** a newer version of that package is approved
- **THEN** the rule remains disabled

#### Scenario: An upgrade does not undo a tuned threshold
- **GIVEN** an operator changed a rule's threshold
- **WHEN** the package is re-approved
- **THEN** the operator's threshold is retained

#### Scenario: Revoking a package disables its rules without deleting them
- **WHEN** a package is denied, revoked or restaged
- **THEN** its rules are disabled
- **AND** the rows remain, so tuning survives a later re-approval

### Requirement: Package rule names cannot collide with core-seeded rules

A rule contributed by a package SHALL be named such that it cannot be adopted or
overwritten by the core rule seeder, which keys rules by name.

#### Scenario: A package shipping a core default's name does not collide
- **GIVEN** a package declaring a rule named `sweep_device_unavailable`
- **WHEN** it is approved
- **THEN** the resulting rule is distinct from the core-seeded rule of that name
- **AND** the core seeder does not adopt or modify it
