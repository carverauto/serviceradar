## ADDED Requirements
### Requirement: Grouped Causal Context Support
The observability pipeline SHALL support grouped causal contexts so normalized events can be evaluated against routing/security propagation domains.

#### Scenario: Event evaluated in grouped context
- **GIVEN** a normalized causal event references one or more grouped contexts
- **WHEN** causal evaluation executes
- **THEN** propagation SHALL be evaluated within the referenced contexts
- **AND** resulting classifications SHALL be emitted for overlay consumption

### Requirement: Causal Explainability Metadata
The system SHALL emit explainability metadata for propagated causal outcomes.

#### Scenario: Propagated state includes evidence metadata
- **GIVEN** a node state is marked affected due to propagation
- **WHEN** overlay state is emitted
- **THEN** metadata SHALL include source signal references and propagation context identifiers
- **AND** operators SHALL be able to inspect why the state was assigned
