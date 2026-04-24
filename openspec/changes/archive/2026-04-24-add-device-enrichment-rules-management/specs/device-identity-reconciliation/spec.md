## ADDED Requirements
### Requirement: Filesystem-Backed Device Enrichment Rules
The system SHALL load device enrichment rules from a layered source model consisting of built-in defaults and optional filesystem overrides located at `/var/lib/serviceradar/rules/device-enrichment/*.yaml`.

#### Scenario: Startup with override rules mounted
- **WHEN** core starts and override rule files are present in `/var/lib/serviceradar/rules/device-enrichment/`
- **THEN** core SHALL load built-in rules first and filesystem rules second
- **AND** filesystem rules SHALL be eligible to override built-in rules by `rule_id`

#### Scenario: Startup without override rules mounted
- **WHEN** core starts and no filesystem rule files are present
- **THEN** core SHALL load built-in rules only
- **AND** enrichment behavior SHALL remain available

### Requirement: Rule Merge and Precedence
The system SHALL merge enrichment rules deterministically by source, `rule_id`, and `priority`.

#### Scenario: Filesystem override replaces built-in rule
- **GIVEN** a built-in rule and a filesystem rule with the same `rule_id`
- **WHEN** rules are merged
- **THEN** the filesystem rule SHALL replace the built-in definition

#### Scenario: Multiple matching rules evaluate deterministically
- **GIVEN** multiple enabled rules match the same device payload
- **WHEN** enrichment runs
- **THEN** the highest-priority rule SHALL win
- **AND** tie-breaking SHALL be deterministic by rule ordering metadata

### Requirement: Rule Validation and Safe Fallback
The system SHALL validate filesystem rules at load time and SHALL continue operating with built-in defaults when filesystem rules are invalid.

#### Scenario: Invalid filesystem rule file
- **WHEN** a filesystem YAML file fails schema validation
- **THEN** core SHALL log the validation error with file and rule context
- **AND** invalid rules SHALL be skipped
- **AND** built-in defaults SHALL remain active

#### Scenario: Rule directory unreadable
- **WHEN** the filesystem rules directory is missing or unreadable
- **THEN** core SHALL emit a startup warning
- **AND** enrichment SHALL continue using built-in rules only

### Requirement: Rule-Driven Classification Provenance
The system SHALL persist provenance for applied enrichment classifications.

#### Scenario: Classification produced by enrichment rule
- **WHEN** an enrichment rule assigns `vendor_name` and/or `type`
- **THEN** device metadata SHALL include `classification_source`, `classification_rule_id`, `classification_confidence`, and `classification_reason`

#### Scenario: No rule match
- **WHEN** no enrichment rule matches an incoming payload
- **THEN** the system SHALL preserve existing classification values when present
- **AND** SHALL fall back to default unknown semantics when classification is absent
