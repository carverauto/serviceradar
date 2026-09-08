# device-identity-reconciliation Specification

## ADDED Requirements

### Requirement: Agent Self-Report Device Identity

An agent SHALL be able to anchor the inventory device representing its own host. The system
SHALL accept a first-party `agent-self-report` device update whose subject is the reporting
agent's host, and SHALL treat that update's `agent_id` as an identifying attribute rather than
an observation. The `agent_id` SHALL be registered as a strong device identifier on the
resolved device.

Because it is first-party evidence a host gives about itself, an `agent-self-report` update MAY
bring a device into existence when nothing resolves — unlike the enrichment-only sources, which
may only describe a device that already exists. It MAY create ONLY the reporting agent's own
host row.

The address carried by a self-report SHALL be the agent's re-detected source address (the value
already used for Hello, PushStatus, SNMP, plugin signals and workload identity), never a value
supplied by an observation the agent forwarded.

#### Scenario: A re-IP'd agent updates its device instead of creating a second one

- **GIVEN** a device exists for agent `agent-a` at `10.0.0.5` with a registered
  `agent_id=agent-a` identifier
- **WHEN** that agent's host is re-addressed to `10.0.1.9` and it sends a self-report
- **THEN** the update SHALL resolve by `agent_id` to the existing device
- **AND** that device's `ip` SHALL become `10.0.1.9`
- **AND** no second device SHALL be created for `10.0.1.9`

#### Scenario: A self-report for a host inventory has never seen creates one

- **GIVEN** no device resolves for agent `agent-b` by any identifier or address
- **WHEN** `agent-b` sends a self-report for `10.0.2.7`
- **THEN** a device SHALL be created for `10.0.2.7`
- **AND** `agent_id=agent-b` SHALL be registered as a strong identifier on it

#### Scenario: A self-report resolves onto a device an observer created first

- **GIVEN** a mapper sighting has already created a device for `10.0.3.4` with no identifiers
- **WHEN** the agent running on `10.0.3.4` sends its first self-report
- **THEN** the self-report SHALL resolve to the existing device by address
- **AND** SHALL register `agent_id` on that device rather than creating a second one

### Requirement: Self-Report Subject Boundary

An `agent-self-report` update SHALL describe exactly one subject: the host the reporting agent
runs on. Observations an agent forwards about OTHER hosts SHALL retain their own sources
(`mapper`, `sweep`, `netprobe-census`, `passive-netprobe`, and the other observer sources) and
SHALL remain subject to observer `agent_id` demotion.

A self-report carrying more than one subject SHALL be rejected rather than partially applied.

This boundary is what makes the source safe to exempt from observer demotion. Without it, a
self-report describing another host would make every such host strong-match the reporting
agent's own device — the collector over-merge that observer demotion exists to prevent.

#### Scenario: A self-report claiming a second subject is rejected

- **WHEN** an `agent-self-report` update carries two subjects
- **THEN** the update SHALL be rejected
- **AND** no device SHALL be created or modified from it

#### Scenario: Forwarded observations do not become self-reports

- **GIVEN** agent `agent-c` forwards a census observation of a neighbouring host
- **WHEN** that observation is ingested
- **THEN** it SHALL keep its observer source
- **AND** `agent-c`'s `agent_id` SHALL NOT be registered as an identifier of the neighbouring host

### Requirement: Agent Identifier Rotation Is a New Anchor

A host re-onboarded under a new `agent_id` SHALL be treated as presenting a new anchor. The
system SHALL NOT infer that two distinct `agent_id` values denote the same host.

Where the resulting devices share some other strong identifier, the scheduled duplicate
reconciliation SHALL merge them by the existing rules. Where they share none, they SHALL remain
distinct rather than being merged on address or hostname overlap.

#### Scenario: Two agent_ids on one host do not silently merge on address

- **GIVEN** a device anchored by `agent_id=agent-old` at `10.0.4.2`
- **WHEN** the host is re-onboarded as `agent-new` and self-reports the same address
- **THEN** the two devices SHALL NOT be merged on the shared address alone

## MODIFIED Requirements

### Requirement: Scheduled Reconciliation Backfill

The scheduled reconciliation SHALL continue to merge devices that share a strong identifier, and
SHALL continue to treat bare-IP overlap as insufficient merge evidence.

It SHALL remain a backstop rather than the primary path by which an agent host keeps one device
across an address change. Where an `agent-self-report` anchors the host by `agent_id`, an address
change SHALL be resolved at ingest and SHALL NOT depend on the sweep to reconcile a duplicate
afterwards.

#### Scenario: A re-addressed agent host does not wait for the sweep

- **GIVEN** an agent host anchored by `agent_id`
- **WHEN** its address changes and it self-reports the new address
- **THEN** the device SHALL carry the new address at ingest
- **AND** no duplicate SHALL be left for the scheduled reconciliation to merge

#### Scenario: Bare-IP overlap still does not merge

- **GIVEN** two devices that share only an IP address and no strong identifier
- **WHEN** the scheduled reconciliation runs
- **THEN** they SHALL NOT be merged
