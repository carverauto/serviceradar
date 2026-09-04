## ADDED Requirements

### Requirement: Policy Editor Manages User-Group Role Profiles

The admin-only Policy Editor SHALL list reusable user groups and let an authorized administrator
assign or clear one role profile per group. Loading SHALL require `settings.rbac.manage` and
`identity.user_groups.view`; mutation SHALL require `settings.rbac.manage` and
`identity.user_groups.manage`. The operation SHALL use a dedicated conjunction-authorized
group-policy action and fresh current-user authority.

#### Scenario: Administrator assigns a group profile

- **GIVEN** an administrator currently has `settings.rbac.manage`
- **AND** a group has no role profile
- **WHEN** the administrator selects a custom role profile for that group
- **THEN** the association SHALL be persisted
- **AND** every current member SHALL receive the profile's permissions on the next current-authority
  check

#### Scenario: Administrator clears a group profile

- **GIVEN** a group has a role profile
- **WHEN** an authorized administrator clears the selection
- **THEN** the association SHALL be removed
- **AND** permissions contributed only by that profile SHALL be revoked for current members

### Requirement: Group Controls Load Asynchronously And Fail Explicitly

The Policy Editor SHALL begin group/profile database loading only after its LiveView is connected.
It SHALL distinguish loading, empty, success, and failure states. A failure SHALL render a generic
retryable error without exposing internal details and MUST NOT be rendered as an empty group list.

#### Scenario: Disconnected render does not query group assignments

- **GIVEN** the Policy Editor is rendering its disconnected response
- **WHEN** mount completes before the socket connects
- **THEN** no group/profile assignment query SHALL start
- **AND** the page SHALL render a loading placeholder

#### Scenario: Group query failure is not an empty state

- **GIVEN** the connected group/profile query fails
- **WHEN** the async result is rendered
- **THEN** the page SHALL show a generic failure and retry control
- **AND** it SHALL NOT claim that no groups exist
- **AND** it SHALL NOT send the internal error term to the browser

### Requirement: Policy Editor Manages Dashboard Group Audiences

For a selected user group, the Policy Editor SHALL show authored dashboards and packaged dashboard
instances the current actor is authorized to manage and SHALL manage explicit group view access
through the existing dashboard-specific grant resources. It MUST NOT create a generic ACL or make a
role profile a dashboard-grant subject.

#### Scenario: Authored dashboard view is granted to a group

- **GIVEN** an administrator can manage RBAC and share an authored dashboard
- **WHEN** they enable explicit view access for the selected group
- **THEN** the system SHALL create or preserve a group-subject `DashboardAccessGrant`

#### Scenario: Package dashboard view is granted to a group

- **GIVEN** an administrator can manage RBAC and share a packaged dashboard instance
- **WHEN** they enable explicit view access for the selected group
- **THEN** the system SHALL create or preserve a group-subject `DashboardInstanceAccessGrant`

#### Scenario: Local and central controls agree

- **GIVEN** a dashboard-local sharing surface and the central Policy Editor both manage group view
  access
- **WHEN** either surface changes the grant
- **THEN** both SHALL use the same monotonic server operation
- **AND** the other surface SHALL observe the canonical result after reload

### Requirement: Dashboard Group View Mutations Are Monotonic

Ensuring group view SHALL create `:view` only when no stronger grant exists and MUST NOT downgrade
an existing `:edit` grant, including under concurrent view/edit requests. Revoking group view SHALL
delete only an exact `:view` grant and MUST NOT delete or downgrade `:edit`.

Every first-party group-subject grant mutation SHALL use one coordinator that serializes
`(dashboard source, target, group)` before rereading the expected fingerprint. Unsupported direct
group-grant actions SHALL fail before persistence. User-subject grant behavior is unchanged.

#### Scenario: Ensure view preserves edit

- **GIVEN** a group already has an `:edit` grant on a dashboard
- **WHEN** an administrator ensures group view from the Policy Editor
- **THEN** the canonical grant SHALL remain `:edit`

#### Scenario: Revoke view preserves edit

- **GIVEN** a group has an `:edit` grant on a dashboard
- **WHEN** an administrator disables the view toggle
- **THEN** the canonical grant SHALL remain `:edit`
- **AND** the UI SHALL continue to label it as stronger access

#### Scenario: Private package becomes shared atomically

- **GIVEN** a packaged dashboard instance is private
- **WHEN** an administrator grants group view
- **THEN** visibility SHALL become `:shared` in the same transaction as the grant
- **AND** another observer SHALL NOT see a committed ineffective group grant on a private target

#### Scenario: Revoke does not tighten package visibility

- **GIVEN** a shared packaged dashboard loses its last exact `:view` group grant
- **WHEN** the revoke transaction commits
- **THEN** the instance SHALL remain `:shared`

#### Scenario: Concurrent local edit makes a central row stale

- **GIVEN** the Policy Editor rendered a group row with no explicit grant
- **AND** a dashboard-local editor concurrently grants that group `:edit`
- **WHEN** the Policy Editor's delayed view event reaches the serialized coordinator
- **THEN** the expected fingerprint SHALL be stale and no view mutation or success audit SHALL occur
- **AND** the persisted grant SHALL remain `:edit`

### Requirement: Dashboard Visibility And Bypasses Are Explicit

The central audience editor SHALL describe explicit group grants rather than claiming to be an
exclusive access list. Public dashboards SHALL be shown as already available under their
source-specific base read gate and read-only in this editor. Stronger `:edit` grants and generic
administrative-bypass guidance SHALL be visibly distinguished from exact `:view` grants. The editor
MUST NOT claim to compute every selected-group member's other effective permission sources.

#### Scenario: Public dashboard cannot receive a redundant view grant

- **GIVEN** a dashboard is public
- **WHEN** it is rendered in the group audience editor
- **THEN** an authored row SHALL state that users with analytics access can view it
- **AND** a packaged row SHALL state that authenticated users can view it
- **AND** the group view control SHALL be disabled
- **AND** no redundant group grant SHALL be created

#### Scenario: Global bypass guidance is not represented as an explicit group grant

- **GIVEN** the selected group has no row-level grant
- **WHEN** the audience row renders
- **THEN** it SHALL explain that the source's global bypass permission can independently confer
  access
- **AND** it SHALL NOT mark the group as having an explicit grant

### Requirement: Dashboard Sources Page Independently With Bounded State

Authored and packaged dashboard lists SHALL use independent stable keyset cursors. Each current page
SHALL be rendered through a source-specific bounded LiveView stream and matched by a server-owned
expected-state window no larger than that page. Paging one source SHALL NOT reset the other source.
Each source SHALL retain only the current page's before/after keysets and MUST NOT accumulate an
unbounded navigation history.

#### Scenario: Paging authored dashboards preserves package state

- **GIVEN** both source lists have loaded
- **WHEN** the administrator advances the authored-dashboard cursor
- **THEN** only the authored stream and expected-state window SHALL be replaced
- **AND** the packaged dashboard page, cursor, and error state SHALL remain unchanged

#### Scenario: Paged-out row is no longer actionable

- **GIVEN** a row token belonged to the prior authored page
- **WHEN** the administrator advances to the next page and later submits that old token
- **THEN** the server SHALL reject it without mutation
- **AND** the current expected-state window SHALL remain bounded to the current page

### Requirement: Dashboard Mutation Events Carry Intent Not Canonical State

Browser events SHALL carry only the selected group token, an opaque source-row token, and the
requested operation. Before writing, the server SHALL resolve those tokens from its bounded state,
require the row token to be bound to the selected group identity and current group-selection epoch,
reload the authorized target and explicit grant, and compare their canonical fingerprint with the
server-held expectation. Browser-supplied target IDs, access values, visibility, timestamps, or
expected versions MUST NOT be trusted as canonical state.

#### Scenario: Canonical state changed after render

- **GIVEN** a dashboard row was rendered with no explicit group grant
- **AND** another administrator creates or edits the grant before the first administrator toggles it
- **WHEN** the delayed toggle event is handled
- **THEN** no mutation SHALL be applied from the stale row
- **AND** the affected source SHALL reload
- **AND** the user SHALL see a stale-state notice

#### Scenario: Browser forges target state

- **GIVEN** a browser submits an unknown row token or additional forged dashboard/grant fields
- **WHEN** the event is handled
- **THEN** the server SHALL ignore the additional fields and reject an unknown token
- **AND** no target or grant SHALL be mutated

#### Scenario: Row token is mixed with another group

- **GIVEN** a row token was issued for one selected group and group-selection epoch
- **WHEN** the browser submits it with another group token or after the selected group changes
- **THEN** the server SHALL reject the event as stale
- **AND** no target or grant SHALL be mutated

### Requirement: Dashboard Group Audience Mutations Are Audited After Commit

Successful group-view ensure/revoke operations SHALL submit one append-only audit record after their
transaction commits, including any packaged-dashboard visibility transition. Denied or rolled-back
operations SHALL NOT submit a success record. Audit-delivery failure SHALL be logged and MUST NOT
reject or undo the committed dashboard grant. Crash-proof exactly-once delivery is not part of this
change.

#### Scenario: Committed group view emits one success event

- **GIVEN** an authorized dashboard group-view mutation
- **WHEN** its transaction commits
- **THEN** one success audit submission SHALL identify the actor, group, target kind, target, and
  operation

#### Scenario: Dashboard audit failure does not roll back grant

- **GIVEN** a dashboard group-view transaction commits
- **AND** subsequent audit delivery fails
- **WHEN** the service returns
- **THEN** the canonical grant and visibility change SHALL remain committed
- **AND** the audit-delivery failure SHALL be logged

### Requirement: Dashboard Audience Authorization Is Rechecked

Every dashboard-audience load and mutation SHALL use the real current actor and authorized Ash
reads/writes. A Policy Editor mutation SHALL use dedicated actions that require fresh
`settings.rbac.manage` authority AND the source-specific share permission AND a source-specific
target-management path. Authored paths are owner, explicit `:edit`, or
`analytics.dashboards.edit`; packaged paths are owner, explicit `:edit`, or
`dashboards.packages.view_all`. The actions MUST NOT rely on generic package actions whose policy
checks are alternatives. Revocation while the editor is open SHALL take effect on the next
mutation.

#### Scenario: Source-specific share permission is missing

- **GIVEN** a user has `settings.rbac.manage` but lacks the authored-dashboard share permission
- **WHEN** they attempt to change an authored dashboard audience
- **THEN** the mutation SHALL be denied
- **AND** no grant, audit success event, or visibility change SHALL occur

#### Scenario: One source fails independently

- **GIVEN** the authored dashboard page is loaded
- **AND** the packaged dashboard query fails
- **WHEN** the audience editor renders
- **THEN** the authored stream SHALL remain available
- **AND** the packaged section SHALL show a generic retryable failure
- **AND** internal error details SHALL not be exposed

#### Scenario: Caller-owned dashboard transaction is rejected

- **GIVEN** application code has already opened a repository transaction
- **WHEN** it invokes a public dashboard group-view mutation
- **THEN** the mutation SHALL return `{:error, :outer_transaction_not_supported}`
- **AND** persistence and audit delivery SHALL remain unchanged
