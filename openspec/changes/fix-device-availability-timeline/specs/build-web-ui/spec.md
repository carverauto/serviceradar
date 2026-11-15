## ADDED Requirements

### Requirement: Device availability timeline shows merged availability history
The device Availability Timeline SHALL render the history of the device's merged availability state, the same value the availability badge shows, built from the stored availability history records and the device's current decision, and SHALL NOT recompute availability from probe samples.
The current state SHALL cover the time since the device's `availability_changed_at`; each history record SHALL cover the interval from its from-since time to its changed-at time in its from state. Time covered by neither SHALL be shown as unknown and SHALL NOT be synthesized as available or unavailable.
A bucket SHALL be offline when the device was unavailable for any part of it, online when every known part of it was available, and unknown when no part of it is known; an offline bucket's tooltip SHALL show the minutes the device was down in it, and uptime SHALL be available time over known time.
When an agent is selected, the timeline SHALL show that agent's raw probe history, labelled as that agent's probe history.
The merged-history timeline SHALL render only when the availability resolver is authoritative; in the `legacy` and `shadow` modes the timeline SHALL show probe history, labelled as probe history.

#### Scenario: A controller-decided device agrees with its badge
- **GIVEN** a device decided available by its managing controller since before the window, while one probing agent cannot reach it
- **WHEN** the device page renders the timeline with no agent selected
- **THEN** every bucket since the decision is online, matching the badge

#### Scenario: Time before any recorded state is unknown
- **GIVEN** a device whose first decision was two hours ago and which has no earlier history record
- **WHEN** the 24-hour timeline renders
- **THEN** the buckets before that decision are unknown

#### Scenario: Before the resolver is authoritative the timeline is labelled probe history
- **GIVEN** the availability resolver is in `shadow` mode
- **WHEN** the device page renders the timeline
- **THEN** the timeline shows probe history and is labelled as probe history

#### Scenario: A selected agent shows its own probes
- **WHEN** the operator selects an agent on the timeline
- **THEN** the timeline shows that agent's probe results per bucket, labelled as that agent's probe history
