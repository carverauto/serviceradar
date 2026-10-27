## MODIFIED Requirements

### Requirement: Armis Northbound Availability Is Not Changed Silently By Merged Availability
The Armis northbound updater SHALL, for a source with a selected availability agent, push that agent's latest per-agent result exactly as before merged availability was introduced, and SHALL NOT change the value pushed for a source without a selected agent until an operator explicitly selects an agent or adopts merged availability for that source.
Existing sources without a selected agent SHALL start in `legacy` availability semantics. A new source SHALL either select an agent or use `merged` semantics. In `legacy` semantics the updater SHALL read the legacy availability value maintained for compatibility, which the legacy writers keep computing for every device, which a new device gets from its initial `is_available`, and which upgrading seeds from `is_available` for any device that had none before the resolver took `is_available` over. In `merged` semantics it SHALL read the canonical availability state and SHALL withhold devices whose state is `unknown`. Removal of the legacy availability writers SHALL NOT proceed while any source remains in `legacy` semantics.
Only an operator's adopt action SHALL change a source from `legacy` to `merged` semantics. The single exception is the upgrade that removes the staged rollout: on a deployment that had not cut over (mode `legacy` or `shadow`), every source in `merged` semantics with no selected agent, which until then pushed the mirror of the legacy value, SHALL be set to `legacy` semantics once, after the compatibility store is seeded and before the mirror is removed, with an append-only record of each such change and its reason, so that it keeps pushing the same value.

#### Scenario: Agent-selected source is unchanged
- **GIVEN** an Armis northbound source whose availability agent is the agent expected to be blocked
- **AND** that agent cannot reach a linked device whose merged state is `available`
- **WHEN** the northbound run builds its candidates
- **THEN** the device SHALL be pushed as not available from that agent, exactly as before merged availability

#### Scenario: Canonical source keeps legacy semantics through the upgrade
- **GIVEN** an existing Armis northbound source with no selected agent
- **WHEN** the deployment upgrades to the release that removes the staged rollout, from any mode
- **THEN** the source SHALL push byte-identical values for every linked device
- **AND** the source settings SHALL show how many pushed values would change under merged availability

#### Scenario: A merged source on an install that never cut over keeps its pushes
- **GIVEN** an Armis northbound source in `merged` semantics with no selected agent, on a deployment in mode `legacy`
- **WHEN** the deployment upgrades to the release that removes the staged rollout
- **THEN** the source SHALL be in `legacy` semantics, with a record of the change and its reason
- **AND** it SHALL push byte-identical values, withholding exactly the devices it withheld before

#### Scenario: An agent-selected source is not changed by the upgrade
- **GIVEN** an Armis northbound source with a selected availability agent
- **WHEN** the deployment upgrades from any mode
- **THEN** its semantics and its pushed values SHALL be unchanged

#### Scenario: A device created after the upgrade has a legacy value
- **GIVEN** an existing canonical Armis northbound source in `legacy` semantics
- **WHEN** a linked device is created after the upgrade
- **THEN** the device SHALL have a compatibility value
- **AND** the source SHALL push that value, never the merged device column

#### Scenario: Device without a later legacy write keeps its legacy value
- **GIVEN** an existing canonical Armis northbound source in `legacy` semantics
- **AND** a linked device whose legacy availability was `true` at the upgrade and that no legacy writer updates afterwards
- **WHEN** the northbound run builds its candidates after the upgrade
- **THEN** the device SHALL be pushed as available

#### Scenario: Operator adopts merged availability
- **GIVEN** a canonical Armis northbound source in `legacy` semantics
- **WHEN** an operator adopts merged availability for the source
- **THEN** subsequent runs SHALL push the canonical availability state
- **AND** devices whose state is `unknown` SHALL be withheld rather than pushed as unavailable
