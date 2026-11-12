## ADDED Requirements

### Requirement: Membership quarantine records its reason
ServiceRadar SHALL record a typed reason and a time whenever it sets an AWX host membership to `quarantined`, at every writer that does so, and storage MUST reject a quarantined membership without a reason.

The reasons are `ambiguous_device_match` (more than one device matches the AWX source tuple), `approved_device_changed` (an approved link now matches exactly one different device), `approved_link_lost_match` (an approved link now matches no device), `approved_membership_not_current` (an approved membership that had expired is observed again), `canonical_device_deleted` (the canonical device of an approved membership was deleted or its identity purged) and `predates_reason_recording` (quarantined before reasons were recorded). Inventory synchronization records the source observation time; the device-deletion path records the time of the deletion. A quarantine is a property of one AWX-to-device link and is distinct from a device-wide target hold.

#### Scenario: Several devices match the AWX host
- **WHEN** synchronization finds more than one device carrying the membership's AWX source tuple
- **THEN** the membership SHALL become `quarantined` with reason `ambiguous_device_match` and the observation time

#### Scenario: Approved link now matches a different device
- **GIVEN** an approved membership linked to one device
- **WHEN** synchronization finds exactly one matching device and it is a different device
- **THEN** the membership SHALL become `quarantined` with reason `approved_device_changed`

#### Scenario: Approved link matches no device
- **GIVEN** an approved membership
- **WHEN** synchronization finds no device carrying its AWX source tuple
- **THEN** the membership SHALL become `quarantined` with reason `approved_link_lost_match`

#### Scenario: Approved membership returns after expiring
- **GIVEN** an approved membership that expired because a complete observation did not report its host
- **WHEN** a later observation reports the host again with the same single matching device
- **THEN** the membership SHALL become `quarantined` with reason `approved_membership_not_current`

#### Scenario: Linked device is deleted
- **WHEN** the canonical device of an approved membership is deleted or its identity is purged
- **THEN** the membership SHALL become `quarantined` with reason `canonical_device_deleted` and the time of the deletion

#### Scenario: Quarantine is sticky and keeps its first reason
- **GIVEN** a quarantined membership
- **WHEN** synchronization observes its host again, whatever the current matches are
- **THEN** the membership SHALL stay `quarantined` with its original reason and time
- **AND** its link evidence SHALL show the current matches

#### Scenario: Rows quarantined before reasons were recorded
- **WHEN** the migration that adds reasons runs over memberships that are already quarantined
- **THEN** each SHALL be marked `predates_reason_recording` with no quarantine time
- **AND** no reason SHALL be inferred from its evidence

#### Scenario: A writer omits the reason
- **WHEN** any write would leave a membership `quarantined` without a reason, or give a non-quarantined membership a reason
- **THEN** storage SHALL reject the write

#### Scenario: Reason is visible to readers
- **WHEN** an authorized principal lists memberships through the API
- **THEN** each membership SHALL include its quarantine reason and quarantine time, both null when it is not quarantined

### Requirement: A human release is the only exit from membership quarantine
ServiceRadar SHALL let a human principal holding `ansible.controllers.manage` release one quarantined AWX host membership by submitting the exact evidence displayed, SHALL re-evaluate the membership's AWX source tuple against current device inventory when it does so, and MUST NOT let any release or synchronization move a quarantined membership to `approved`.

Synchronization SHALL NOT clear a quarantine. The release request SHALL contain the controller ID, inventory ID, AWX host ID, source generation, source fingerprint and link-evidence digest of the quarantined membership and nothing else. Authority SHALL be re-read from storage as for approval; system actors and OAuth clients SHALL be refused. Release SHALL serialize with synchronization of the same controller. A released membership SHALL clear its reason and time, keep its source generation, and from then on follow the normal reconciliation rules, which can quarantine it again with a new reason. Every release SHALL append a record of the principal, the time, the prior reason and time, the evidence at release and the resulting disposition, device and evidence, in the same transaction as the membership update. Releasing a membership SHALL NOT clear a target hold, and clearing a target hold SHALL NOT release a membership.

#### Scenario: Exactly one device matches now
- **GIVEN** a quarantined, current membership whose AWX source tuple now matches exactly one device
- **WHEN** an authorized human releases it with the displayed evidence
- **THEN** the membership SHALL become `proposed` for that device with fresh single-match evidence
- **AND** it SHALL NOT be launchable until a human approves it through the normal approval

#### Scenario: No device matches now
- **WHEN** an authorized human releases a quarantined membership whose source tuple matches no device
- **THEN** the membership SHALL become `unlinked` with fresh evidence and no device

#### Scenario: Several devices still match
- **WHEN** an authorized human releases a quarantined membership whose source tuple matches more than one device
- **THEN** ServiceRadar SHALL refuse and report the current matching devices
- **AND** the membership SHALL stay `quarantined` with its reason unchanged and no release record SHALL be written

#### Scenario: Evidence changed after it was displayed
- **WHEN** the submitted identity, generation, fingerprint or evidence digest no longer matches the quarantined membership
- **THEN** ServiceRadar SHALL refuse without changing the membership

#### Scenario: Membership is not quarantined or not current
- **WHEN** release is requested for a membership that is not quarantined, or that has expired
- **THEN** ServiceRadar SHALL refuse without changing it

#### Scenario: Non-human or unauthorized caller
- **WHEN** a system actor, an OAuth client, a disabled user, or a user whose stored authority lacks `ansible.controllers.manage` requests a release
- **THEN** ServiceRadar SHALL refuse without changing the membership

#### Scenario: Synchronization never releases
- **GIVEN** a quarantined membership whose source tuple now matches exactly one device
- **WHEN** synchronization runs and no human releases it
- **THEN** the membership SHALL stay `quarantined`

#### Scenario: Released membership is quarantined again
- **GIVEN** a membership released to `proposed`
- **WHEN** a later synchronization finds more than one matching device
- **THEN** the membership SHALL become `quarantined` again with reason `ambiguous_device_match` and that observation's time

#### Scenario: Release is recorded
- **WHEN** a release succeeds
- **THEN** one release record SHALL hold the membership and source tuple, the releasing principal, the release time, the prior reason and time, the prior evidence, and the resulting disposition, device and evidence
- **AND** release records SHALL NOT be updated or deleted through the application

#### Scenario: Release through the admin API
- **WHEN** a human principal sends `POST /api/admin/ansible-memberships/{id}/release` with exactly the six evidence fields
- **THEN** ServiceRadar SHALL perform the release as the authenticated user and return the updated membership
- **AND** a refusal because several devices match SHALL return the error code `membership_link_ambiguous` with the matching device UIDs
