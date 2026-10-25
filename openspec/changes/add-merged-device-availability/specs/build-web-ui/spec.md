## ADDED Requirements

### Requirement: Device Availability Badge Reads Canonical State
The device list and device detail pages SHALL render each device's availability badge from the device's canonical availability state, and web-ng MUST NOT compute an availability value of its own for the badge.
The badge SHALL show Online, Offline or Unknown, and its tooltip SHALL name the deciding source and the time of the decision.

#### Scenario: Badge agrees with sort and count
- **GIVEN** a device counted in the Available stat card
- **WHEN** the device list renders
- **THEN** the device's badge SHALL show Online
- **AND** the device SHALL sort with the other available devices

#### Scenario: Unknown device
- **GIVEN** a device with no fresh availability evidence
- **WHEN** the device list renders
- **THEN** the badge SHALL show Unknown
- **AND** the Unknown stat card SHALL include the device

### Requirement: Device List Shows Per-Agent Reachability
The device list SHALL show, next to the merged badge, how many probing agents currently reach the device out of how many probe it, and SHALL show a partial-reachability marker whenever any fresh non-control agent cannot reach the device, so the merged badge never hides an unreachable result from a specific agent.
Negative-control agents SHALL be shown separately as blocked-as-expected or as a policy violation.

#### Scenario: Controller-decided device with failing sweeps
- **GIVEN** a device resolved available by its managing controller while both of its probing agents fail to reach it
- **WHEN** the device list renders
- **THEN** the row SHALL show Online with "up from 0 of 2 agents" and a partial-reachability marker
- **AND** the tooltip SHALL list each agent's latest result

#### Scenario: Isolation verified
- **GIVEN** a device reached by its witness agent and not reached by an agent expected to be blocked
- **WHEN** the device list renders
- **THEN** the row SHALL show Online and a blocked-as-expected indicator

#### Scenario: Isolation violated
- **GIVEN** a device reached by an agent expected to be blocked
- **WHEN** the device list renders
- **THEN** the row SHALL show a policy-violation indicator naming the count of such agents

### Requirement: Device Detail Explains Availability
The device detail page SHALL keep the per-agent availability section with each agent's latest result, check time and role (witness, negative control, pinned, ineligible), and SHALL add an evidence section listing each non-probe evidence record with source kind, authority class, state, observed time, expiry, confirmations and eligibility, marking which record decided the canonical state.

#### Scenario: Operator reads the evidence
- **GIVEN** a device with controller evidence and results from two probing agents
- **WHEN** an operator opens the device detail page
- **THEN** the page SHALL list both agents' latest results with their check times
- **AND** SHALL list the controller evidence record
- **AND** SHALL mark the record that decided the canonical state

### Requirement: Availability Rollout Control In Settings
The Availability Sources settings page SHALL show the deployment's availability mode, its mode control (`auto`, `hold_legacy` or `hold_shadow`) and each condition of the last readiness evaluation, SHALL let a user with the network settings permission change the control, and SHALL show a control pinned by deployment configuration read-only.

#### Scenario: Editor changes the control
- **GIVEN** an unpinned control and a user with the network settings permission
- **WHEN** the user selects `hold_legacy` and confirms
- **THEN** the control SHALL be stored and applied without waiting for the next scheduled run

#### Scenario: Pinned control is read-only
- **GIVEN** a control pinned by deployment configuration
- **WHEN** a user opens the page
- **THEN** the page SHALL show the pinned value as the selected control, including when the stored control differs, and the configuration that pins it
- **AND** every control choice SHALL be disabled

