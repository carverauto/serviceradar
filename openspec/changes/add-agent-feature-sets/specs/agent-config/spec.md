## ADDED Requirements

### Requirement: Add-on Assignment Compilation And Delivery
The control plane SHALL compile per-agent and per-cohort add-on (feature-set)
assignments into the existing versioned agent configuration and deliver them through
the existing distribution pipeline. The compiled add-on section SHALL participate in
the configuration version hash so it gains change detection, cache invalidation, and
both push and poll delivery. A configuration change to an add-on assignment SHALL be
dispatched to exactly the targeted agents.

#### Scenario: Assignment is compiled into versioned config
- **GIVEN** an approved add-on assigned and enabled for an agent
- **WHEN** the control plane compiles that agent's effective configuration
- **THEN** the configuration SHALL include a typed add-on assignment section with the add-on id, version, delivery and supervision model, the per-architecture artifact reference and content hash, and validated parameters
- **AND** the add-on section SHALL be included in the configuration version hash

#### Scenario: Selection change pushes to targeted agents only
- **GIVEN** an operator changes an add-on assignment for a set of agents
- **WHEN** the change is saved
- **THEN** the control plane SHALL recompile effective configuration for the targeted agents
- **AND** SHALL push the updated configuration to the online targeted agents
- **AND** SHALL NOT push add-on configuration to agents that are not targeted

#### Scenario: Add-on artifacts are referenced, not embedded
- **GIVEN** a pushed-artifact add-on assignment delivered in agent configuration
- **WHEN** the configuration is built
- **THEN** the artifact SHALL be referenced by object key and content hash with a header-based download token
- **AND** the download token SHALL NOT be embedded in a URL
