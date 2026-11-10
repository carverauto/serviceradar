## ADDED Requirements

### Requirement: Target readiness names the reason and the remedy
ServiceRadar SHALL report, for a device and a controller, whether the device is launchable, and when it is not SHALL report one specific reason derived from the same predicates launch enforces, together with the action that resolves it. When more than one reason applies, readiness SHALL report the first that applies in this order: skipped by synchronization, not in AWX inventory, ambiguous, host disabled or not current, missing address, quarantined, membership review needed, held, no approved binding. A missing address therefore precedes quarantine and membership review, because approval of a membership without an address is refused.

#### Scenario: Membership awaits review
- **GIVEN** a device whose only membership on the controller is `proposed` and whose AWX host has a usable address
- **WHEN** readiness is requested
- **THEN** the reason SHALL be that membership review is needed
- **AND** the response SHALL reference the membership to review

#### Scenario: Host has no address
- **GIVEN** a membership whose AWX host has no usable address
- **WHEN** readiness is requested
- **THEN** the reason SHALL be the missing address
- **AND** the device SHALL NOT be reported launchable

#### Scenario: Proposed membership without an address
- **GIVEN** a device whose only membership on the controller is `proposed` and whose AWX host has no usable address
- **WHEN** readiness is requested
- **THEN** the reason SHALL be the missing address and not membership review

#### Scenario: Host skipped by synchronization
- **WHEN** AWX has a host for the device that synchronization skipped for lack of an anchor
- **THEN** the reason SHALL be that synchronization skipped the host, and not that the device is absent from AWX inventory

#### Scenario: Device is in no AWX inventory
- **WHEN** no inventory of the controller has an AWX host for the device
- **THEN** the reason SHALL say the device is not in AWX inventory

#### Scenario: Readiness agrees with launch
- **WHEN** readiness reports a device launchable for an automation
- **THEN** preparing an operation for that device and automation SHALL NOT fail for a membership or address reason that readiness could have reported

#### Scenario: Approval of an unlaunchable membership
- **WHEN** a principal approves a membership that has no usable address
- **THEN** ServiceRadar SHALL refuse with a reason naming the address

### Requirement: Quarantine has a reviewed exit
ServiceRadar SHALL let a human principal holding the membership permission release a quarantined membership to `proposed`, recording the principal and a reason, and MUST NOT return a released membership to `approved` without a new approval.

#### Scenario: Release after the cause is resolved
- **GIVEN** a quarantined membership whose AWX host now matches exactly one device
- **WHEN** an authorized human principal releases it with a reason
- **THEN** the membership SHALL become `proposed`
- **AND** it SHALL NOT be launchable until it is approved again

#### Scenario: Release while still ambiguous
- **WHEN** release is requested for a membership whose host still matches no device or more than one
- **THEN** ServiceRadar SHALL refuse and report the current matches

#### Scenario: Quarantine evidence is visible
- **WHEN** an authorized principal reads a quarantined membership
- **THEN** the response SHALL include the non-secret evidence that explains the quarantine
