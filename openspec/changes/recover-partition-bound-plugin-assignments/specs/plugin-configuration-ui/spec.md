## ADDED Requirements

### Requirement: Authenticated partition provenance in assignment UI
The plugin package assignment UI SHALL show the current authenticated partition state for the selected agent and explain that the value is derived from the live server-observed mTLS control session. The UI SHALL NOT render an editable partition selector or submit an operator-selected partition value.

#### Scenario: Selected online agent has a current partition
- **GIVEN** an operator with plugin assignment permission selects an online agent
- **AND** the server resolves current control-session evidence for partition `default`
- **WHEN** the assignment form renders its agent context
- **THEN** the UI displays `Authenticated partition: default`
- **AND** it explains that the value will be rechecked on save
- **AND** no editable partition input is present

#### Scenario: Selected agent has no trustworthy partition evidence
- **GIVEN** an operator selects an offline agent or an agent without matching control-session evidence
- **WHEN** the assignment form renders its agent context
- **THEN** the UI identifies the authenticated partition as unavailable
- **AND** it does not imply that a saved or default partition will be used
- **AND** it prevents or clearly fails the assignment action until evidence is available

### Requirement: Automatic recovery is separated from assignment editing
The plugin configuration UI SHALL keep historical recovery records out of the
normal assignment editor. It SHALL NOT require an operator to reconcile a
policy-owned row, display repeated recovery warnings for duplicate historical
rows, or present a manual recovery action per assignment. It SHALL show current
live assignments normally and place secret-safe recovery history in a collapsed,
non-actionable detail surface.

#### Scenario: Package detail contains legacy history
- **GIVEN** a package has current assignments and one or more disabled unbound historical assignments
- **WHEN** an operator opens the package assignment editor
- **THEN** the normal assignment list shows current assignments and their current controls
- **AND** historical rows do not render repeated warning panels, policy-reconcile buttons, or per-row reapproval buttons
- **AND** a collapsed history summary may show only normalized completion or exception state

#### Scenario: Policy recovery runs without a UI action
- **GIVEN** a disabled unbound policy assignment has a current authoritative owner
- **WHEN** an operator views its package or recovery summary
- **THEN** the UI does not ask the operator to start or approve reconciliation
- **AND** it shows only aggregate automatic progress or an actionable current-owner exception
- **AND** the control plane remains responsible for owner, credential, schema, and identity checks

#### Scenario: Historical identifiers are not primary labels
- **GIVEN** recovery state refers to a plugin package and one or more agents
- **WHEN** the UI renders that state
- **THEN** it uses the approved plugin name, human-readable reason, and affected-agent count as the primary labels
- **AND** package UUIDs, recovery request IDs, replacement IDs, and raw audit identifiers appear only in explicitly opened technical detail when authorized

#### Scenario: Quarantined history does not block a fresh assignment
- **GIVEN** an agent has only disabled unbound historical rows for a plugin
- **AND** an authorized operator submits the normal assignment form with current configuration
- **WHEN** the UI resolves whether to create or update an assignment
- **THEN** it excludes every unbound historical row from current-assignment lookup
- **AND** it submits a fresh create through the normal partition-binding path
- **AND** it does not display an instruction to use a per-row recovery action

### Requirement: Tenant-scoped manual adoption plan
The plugin configuration UI SHALL provide at most one tenant-scoped confirmation
for compatible manual legacy assignments that cannot be recovered from immutable
principal-continuity evidence. The preview SHALL summarize eligible, waiting, and
blocked logical assignments; it SHALL NOT ask the operator to approve each agent,
package, or historical row separately. Confirmation SHALL submit only the
immutable plan identifier and explicit tenant-scoped intent, never a partition,
secret value, or caller-edited item list.

#### Scenario: Operator approves compatible manual recovery once
- **GIVEN** the current tenant has multiple compatible manual legacy assignments across multiple agents and plugins
- **AND** an operator is authorized to create assignments in that tenant
- **WHEN** the operator opens the recovery plan
- **THEN** the UI summarizes recognizable plugin names, affected-agent counts, and eligible, waiting, and blocked totals
- **AND** one confirmation approves all immutable eligible items in the plan
- **AND** the UI does not render a confirmation control for every item

#### Scenario: Server rejects a forged or stale plan submission
- **GIVEN** a browser changes plan membership, supplies a partition, replays an expired plan, or submits a plan from another tenant
- **WHEN** the confirmation event reaches the control plane
- **THEN** the action fails without creating or enabling an assignment
- **AND** the UI reports a safe stale-or-unauthorized result without disclosing cross-tenant or secret data

### Requirement: Recovery overview is exception-only
The plugin configuration UI SHALL provide a tenant-scoped, bounded recovery
overview that reports aggregate automatic progress and groups only actionable
exceptions by recognizable plugin and remediation reason. Offline or temporarily
unavailable agents SHALL be shown as waiting and SHALL NOT be presented as tasks
requiring operator action. Completed historical rows SHALL not remain in an
action queue.

#### Scenario: Automatic recovery is progressing normally
- **GIVEN** the tenant has restored items, items waiting for agents, and no actionable exceptions
- **WHEN** an authorized operator opens the Plugins index
- **THEN** the UI shows compact aggregate progress
- **AND** it does not render a legacy-review table, per-row links, or a warning that the operator must process waiting items

#### Scenario: Actionable failures are grouped by remediation
- **GIVEN** multiple logical recovery items fail for the same current schema, credential-policy, unsupported-owner, permission, or conflict reason
- **WHEN** an authorized operator opens recovery exceptions
- **THEN** the UI groups them by plugin name and remediation reason with an affected-agent count
- **AND** it links directly to the current policy, credential rule, configuration, or conflict surface that can resolve the issue
- **AND** individual agent details are disclosed only on demand within the tenant
- **AND** the collection uses bounded keyset pages rather than an unbounded LiveView list

#### Scenario: No cross-tenant recovery metadata is rendered
- **GIVEN** another tenant has recovery progress, plans, or exceptions
- **WHEN** an operator opens the Plugins index in the current tenant
- **THEN** the UI does not render the other tenant's agents, plugins, counts, statuses, plan existence, or recovery-request existence
