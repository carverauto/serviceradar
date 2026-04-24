## ADDED Requirements
### Requirement: Grouped Causal Context Support
The observability pipeline SHALL support grouped causal contexts so normalized events can be evaluated against routing/security propagation domains.

#### Scenario: Event evaluated in grouped context
- **GIVEN** a normalized causal event references one or more grouped contexts
- **WHEN** causal evaluation executes
- **THEN** propagation SHALL be evaluated within the referenced contexts
- **AND** resulting classifications SHALL be emitted for overlay consumption

#### Scenario: Conflicting grouped signal domains resolve deterministically
- **GIVEN** a normalized causal event references multiple signal domains with different precedence
- **WHEN** grouped causal evaluation executes
- **THEN** precedence resolution SHALL be deterministic
- **AND** the chosen primary domain/context SHALL be included in explainability metadata

### Requirement: Causal Explainability Metadata
The system SHALL emit explainability metadata for propagated causal outcomes.

#### Scenario: Propagated state includes evidence metadata
- **GIVEN** a node state is marked affected due to propagation
- **WHEN** overlay state is emitted
- **THEN** metadata SHALL include source signal references and propagation context identifiers
- **AND** operators SHALL be able to inspect why the state was assigned

### Requirement: Grouped Evaluation Guardrails
Grouped causal evaluation SHALL enforce bounded context handling to preserve predictable latency under burst input.

#### Scenario: Context set is bounded under burst input
- **GIVEN** an event carries context references exceeding configured limits
- **WHEN** normalization/evaluation executes
- **THEN** contexts SHALL be truncated to configured bounds
- **AND** guardrail metadata SHALL indicate truncation and applied limits
