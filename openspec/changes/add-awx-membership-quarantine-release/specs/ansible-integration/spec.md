## ADDED Requirements

### Requirement: Membership review shows quarantine reasons and offers release
The Ansible settings membership review SHALL show the quarantine reason and quarantine time on every quarantined membership and SHALL let a human user holding `ansible.controllers.manage` release one quarantined membership through the same `ServiceRadarWebNG.AnsibleAutomation` entry point the API uses.

Each reason SHALL be shown as a short operator-facing explanation; `predates_reason_recording` SHALL read as an unknown cause, and its missing time SHALL read as unknown. The release control SHALL submit exactly the controller ID, inventory ID, AWX host ID, source generation, source fingerprint and link-evidence digest shown for the row, as the logged-in user, after re-checking `ansible.controllers.manage` against current persisted authority. The page SHALL describe the action as releasing a membership quarantine, distinct from a device target hold, and SHALL state that a released membership needs a normal approval before it can launch. It SHALL NOT offer approval of a quarantined row or any way to force a device link.

#### Scenario: Operator sees why a row is quarantined
- **WHEN** the membership list includes a quarantined row
- **THEN** the row SHALL show its reason and when it was quarantined

#### Scenario: Operator releases a quarantined row
- **WHEN** the operator confirms the release of a quarantined row whose host now matches exactly one device
- **THEN** the page SHALL submit the displayed evidence through the shared release entry point
- **AND** the row SHALL be listed as `proposed` and offer the normal approval

#### Scenario: Release refused because several devices match
- **WHEN** the release service refuses because several devices match
- **THEN** the page SHALL show the matching devices and keep the row quarantined
- **AND** it SHALL NOT resubmit the request

#### Scenario: Evidence changed before release
- **WHEN** the release service refuses because the row's evidence changed
- **THEN** the page SHALL reload the row and show its current evidence for a new review

#### Scenario: Quarantined and unlinked rows are counted separately
- **WHEN** the operator filters the membership list
- **THEN** the page SHALL offer separate Quarantined and Unlinked filters, each with its own count, and SHALL NOT group the two under one count
