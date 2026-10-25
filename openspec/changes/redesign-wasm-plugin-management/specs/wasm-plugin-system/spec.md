## ADDED Requirements

### Requirement: Plugin assignment update policy

Every Wasm plugin assignment owner SHALL have an update policy:
`track_latest_approved` or `pinned`. Owners are manual assignments, target
policies and credential rules.

- An owner that tracks the latest approved version SHALL resolve to the newest
  approved, non-revoked package with the same `plugin_id`. It SHALL reach that
  package through a rollout.
- A pinned owner SHALL keep its selected package until an operator changes it.
- Owners of signed, verified first-party packages SHALL default to
  `track_latest_approved`.
- Owners of uploaded, GitHub-imported or third-party packages SHALL default to
  `pinned`.
- Tracking owners SHALL move without an operator by default. A deployment
  setting SHALL be able to turn these automatic rollouts off.

#### Scenario: Tracking owner after a new approval
- **WHEN** a newer version of a first-party plugin is approved
- **THEN** every assignment whose owner tracks the latest approved version is scheduled to move to it through a rollout

#### Scenario: Pinned owner after a new approval
- **WHEN** a newer version is approved and an assignment's owner is pinned
- **THEN** the assignment keeps its package and is reported as behind latest

### Requirement: First-party plugin auto-approval within the approved grant

When the system imports a signed, verified first-party plugin package, it SHALL
compare the package's requested grant with the approved grant of that plugin's
latest approved version.
- **Capabilities, permissions and resources all a subset or equal:** approve it
  automatically and record an audit event marking the approval as automatic.
- **Any widening:** leave it staged for operator review.

This is the only exception to the explicit decision required by "Staged Import
Review and Capability Confirmation". A deployment setting SHALL be able to
disable auto-approval.

#### Scenario: Unchanged grant
- **WHEN** a first-party release ships a new plugin version requesting the same capabilities, permissions and resources as the approved version
- **THEN** the new version is approved automatically and audited as such

#### Scenario: Widened grant
- **WHEN** the new version requests an additional allowed domain
- **THEN** it stays staged and is listed for review with the added domain

### Requirement: Plugin rollouts

Moving assignments to a new plugin version SHALL run as a rollout with:
- a snapshotted target set;
- batches;
- a health gate based on fresh plugin results;
- pause, resume and cancel;
- automatic rollback to the previous stable package when the health gate fails.

#### Scenario: Health gate failure
- **WHEN** a rollout batch's targets report failing results for the new version within the soak period
- **THEN** the rollout stops, those targets return to the previous package, and the owners show `health_gate_failed`

### Requirement: Assignments are never disabled silently

No reconcile, upgrade or rollout SHALL disable an enabled plugin assignment
without recording a reason and, where applicable, the acting operator. Each
owner SHALL expose a status with a stable reason code, at least:
- `ok`
- `targets_unresolved`
- `incompatible_config`
- `awaiting_review`
- `health_gate_failed`
- `rolled_back`

The status SHALL be visible in the plugin management UI.

#### Scenario: Owner target no longer resolves
- **WHEN** a credential rule's target query resolves no devices
- **THEN** its assignments are not disabled
- **AND** the rule and plugin show `targets_unresolved`

## MODIFIED Requirements

### Requirement: Staged Import Review and Capability Confirmation
The system MUST stage every plugin import and require an explicit approve/deny decision with a diff view of requested vs approved capabilities and allowlists before a plugin is distributable, EXCEPT a signed, verified first-party package whose requested capabilities, permissions and resources are a subset of the plugin's currently approved grant, which the system MAY approve automatically under "First-party plugin auto-approval within the approved grant". The first approved version of any plugin MUST always require an explicit decision.

#### Scenario: Import is staged with approve/deny
- **GIVEN** a newly uploaded or GitHub-sourced plugin package
- **WHEN** the package is staged for import
- **THEN** the system presents an approve/deny decision
- **AND** shows a diff view of requested vs approved capabilities and allowlists
- **AND** the package remains inactive until approved

#### Scenario: Capability override on import
- **GIVEN** a plugin requesting `http_request` and an allowlist of `api.example.com`
- **WHEN** an admin removes `http_request` or narrows the allowlist during import
- **THEN** the approved policy is persisted
- **AND** the plugin executes with the approved (reduced) capabilities

#### Scenario: Unapproved plugin not distributable
- **GIVEN** a plugin package that has not been approved
- **WHEN** an agent config is generated
- **THEN** the plugin is excluded from assignments

#### Scenario: Denied import remains blocked
- **GIVEN** a plugin package that was denied during import review
- **WHEN** an admin attempts to assign the plugin to an agent
- **THEN** the assignment is blocked

#### Scenario: First-party update within the approved grant
- **GIVEN** a first-party plugin with an approved version
- **AND** a signed, verified first-party package of a newer version whose requested capabilities, permissions and resources are a subset of the approved grant
- **WHEN** the package is imported
- **THEN** it is approved automatically without an operator decision
- **AND** an audit event records the approval as automatic

