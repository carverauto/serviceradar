## ADDED Requirements

### Requirement: Armis Northbound Availability Is Not Changed Silently By Merged Availability
The Armis northbound updater SHALL, for a source with a selected availability agent, push that agent's latest per-agent result exactly as before merged availability was introduced, and SHALL NOT change the value pushed for a source without a selected agent until an operator explicitly selects an agent or adopts merged availability for that source.
Existing sources without a selected agent SHALL start in `legacy` availability semantics. In `legacy` semantics the updater SHALL read the legacy availability value maintained for compatibility. In `merged` semantics it SHALL read the canonical availability state and SHALL withhold devices whose state is `unknown`. Removal of the legacy availability writers SHALL NOT proceed while any source remains in `legacy` semantics.

#### Scenario: Agent-selected source is unchanged
- **GIVEN** an Armis northbound source whose availability agent is the agent expected to be blocked
- **AND** that agent cannot reach a linked device whose merged state is `available`
- **WHEN** the northbound run builds its candidates
- **THEN** the device SHALL be pushed as not available from that agent, exactly as before merged availability

#### Scenario: Canonical source keeps legacy semantics until reviewed
- **GIVEN** an existing Armis northbound source with no selected agent
- **WHEN** merged availability is cut over
- **THEN** the source SHALL continue to push the legacy availability value
- **AND** the source settings SHALL show how many pushed values would change under merged availability

#### Scenario: Operator adopts merged availability
- **GIVEN** a canonical Armis northbound source in `legacy` semantics
- **WHEN** an operator adopts merged availability for the source
- **THEN** subsequent runs SHALL push the canonical availability state
- **AND** devices whose state is `unknown` SHALL be withheld rather than pushed as unavailable
