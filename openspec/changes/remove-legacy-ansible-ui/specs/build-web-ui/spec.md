## ADDED Requirements

### Requirement: Canonical Ansible Operation History

The web UI SHALL expose Ansible execution history only through `/ansible/operations` and `/ansible/operations/:id`. It SHALL NOT expose a `PlaybookRun` index or detail page, links to `/ansible/runs*`, or migration-oriented comparisons between operation models.

#### Scenario: Operator views operation history

- **GIVEN** an authenticated operator with `ansible.runs.view`
- **WHEN** the operator opens `/ansible/operations`
- **THEN** the UI lists canonical Ansible operations
- **AND** each detail link targets `/ansible/operations/:id`
- **AND** the page contains no link or comparison to a legacy run model

#### Scenario: Retired run URL is requested

- **WHEN** a request targets `/ansible/runs` or `/ansible/runs/:id`
- **THEN** the router SHALL NOT mount a legacy run LiveView
- **AND** the retired path SHALL return not found rather than claim an unrelated operation mapping

#### Scenario: Operator views operation evidence

- **GIVEN** an authenticated operator can view an Ansible operation
- **WHEN** the operator opens `/ansible/operations/:id`
- **THEN** the UI SHALL show the available initiating actor, exact target, controller and inventory scope, content revision, hold, diagnostic, and dispatch evidence
- **AND** the UI SHALL NOT link to or compare against `PlaybookRun` history

#### Scenario: Retained northbound Ansible invocation exists

- **GIVEN** a retained northbound invocation references a provider whose type is `ansible`
- **WHEN** an authorized operator views Ansible operation history or generic Action History
- **THEN** the Ansible pages SHALL show only canonical `AutomationOperation` evidence
- **AND** generic Action History SHALL exclude the retained Ansible invocation
- **AND** the stored provider, descriptor, invocation, and target evidence SHALL NOT be deleted by the UI retirement

### Requirement: Standalone Ansible Pages Preserve the Authenticated Shell

Every retained standalone Ansible LiveView SHALL render inside the ServiceRadar operations shell with the authenticated scope, current path, and page title.

#### Scenario: Operator visits a standalone Ansible page

- **GIVEN** an authenticated operator is authorized for the requested page
- **WHEN** the operator opens `/ansible/catalog`, `/ansible/launch`, `/ansible/operations`, or `/ansible/operations/:id`
- **THEN** the page SHALL render the operations topbar and primary sidebar
- **AND** the shell SHALL show the page title for the requested route

### Requirement: Device Ansible Panel Uses Canonical Operations

The device detail Ansible panel SHALL recognize AWX-managed devices but SHALL load and render execution history only from canonical Ansible operations. It SHALL NOT query, subscribe to, or render `PlaybookRunTarget` history.

#### Scenario: AWX-learned device has operation history

- **GIVEN** a device is recognized as an AWX inventory member
- **AND** canonical Ansible operations have targeted the device
- **WHEN** an authorized operator views the device detail page
- **THEN** the Ansible panel SHALL list recent operations
- **AND** each history link SHALL target `/ansible/operations/:id`
- **AND** no legacy run link, table, badge, or comparison copy SHALL appear

#### Scenario: AWX-learned device has no operation history

- **GIVEN** a device is recognized as an AWX inventory member
- **AND** no canonical Ansible operation has targeted the device
- **WHEN** an authorized operator views the device detail page
- **THEN** the Ansible panel SHALL remain available for launching an operation
- **AND** the panel SHALL show an operation-only empty state
- **AND** retained pre-hardening records SHALL NOT change that empty state

### Requirement: Canonical Ansible Launch Is Separate from Northbound Actions

The device inventory SHALL present canonical Ansible launch and provider-neutral northbound launch as separate actions with separate permissions. Ansible launch SHALL use `/ansible/launch` and SHALL NOT use a northbound Ansible descriptor, invocation, AWX-applicability adapter, or raw `extra_vars` form. Retained Ansible northbound rows MAY remain as internal evidence but SHALL NOT be eligible for operator launch.

#### Scenario: Ansible-only operator selects devices

- **GIVEN** an authenticated operator has `ansible.runs.launch` and does not have `northbound.actions.launch`
- **WHEN** the operator explicitly selects one or more devices in inventory
- **THEN** the toolbar SHALL show **Launch Playbook** and SHALL NOT show **Run Action**
- **AND** activating **Launch Playbook** SHALL navigate to `/ansible/launch?devices=...`
- **AND** the canonical launch service SHALL revalidate the reviewed binding, exact target memberships, current actor, and live AWX resources

#### Scenario: Northbound-only operator selects devices

- **GIVEN** an authenticated operator has `northbound.actions.launch` and does not have `ansible.runs.launch`
- **WHEN** the operator explicitly selects one or more devices in inventory
- **THEN** the toolbar SHALL show **Run Action** and SHALL NOT show **Launch Playbook**
- **AND** the action picker SHALL contain only eligible non-Ansible provider descriptors
- **AND** the northbound permission SHALL NOT authorize canonical Ansible launch

#### Scenario: Retained Ansible descriptor remains enabled

- **GIVEN** a retained northbound provider has type `ansible`
- **AND** one of its historical descriptors remains stored and enabled
- **WHEN** the operator catalog calculates eligible device or interface actions
- **THEN** the descriptor SHALL NOT be returned or rendered
- **AND** catalog reads SHALL NOT synchronize new Ansible descriptors as a side effect

#### Scenario: Provider-neutral action form is rendered

- **GIVEN** an operator selects an eligible non-Ansible action
- **WHEN** the provider-neutral modal opens
- **THEN** it SHALL render only the constrained descriptor schema
- **AND** it SHALL NOT render playbook surveys, git `vars_prompt`, AWX-applicability messaging, or an Ansible raw `extra_vars` control

### Requirement: Retained Ansible Lifecycle Internals Are Not Operator Settings

The settings UI SHALL expose controller and repository management only. It SHALL NOT expose retained schedule, run-ingestion, watchdog, or retention internals as supported operator workflows or configuration. Stored records and backend workers MAY remain for audit and a later architectural migration.

#### Scenario: Administrator opens Ansible settings

- **GIVEN** retained Ansible lifecycle records and workers do not create or govern canonical operations
- **WHEN** an authorized administrator opens `/settings/ansible`
- **THEN** the UI SHALL NOT render a Schedules tab
- **AND** the UI SHALL NOT render a Retention tab
- **AND** the UI SHALL NOT offer schedule creation, editing, enablement, disablement, or deletion controls
- **AND** the controller form SHALL NOT expose a run-pulse setting

### Requirement: Canonical Ansible Actions Enforce Exact Authority

The Ansible UI SHALL authorize launch as creation of a canonical operation and SHALL enforce controller and repository settings permissions independently. Retained RBAC key names MAY remain for deployed-profile compatibility, but their operator-facing labels and descriptions SHALL describe operations, reviewed playbook launch, or reserved non-executable schedule authority. `ansible.runs.launch`, `ansible.runs.view`, `northbound.actions.launch`, and `northbound.actions.view` SHALL remain independent and SHALL NOT substitute for one another.

#### Scenario: Launch-only operator opens the launch page

- **GIVEN** an authenticated operator has `ansible.runs.launch` and does not have `ansible.runs.view`
- **AND** an explicit canonical target, parse-valid AWX playbook, current approved binding, and current approved membership exist
- **WHEN** the operator opens `/ansible/launch?devices=...` and selects that playbook
- **THEN** the route SHALL authorize the canonical create action
- **AND** the launch resolver's narrow playbook, current-binding, and current-device-membership reads SHALL succeed
- **AND** the UI SHALL show real target and binding readiness rather than an empty picker
- **AND** validation and submission events SHALL remain available without granting general catalog or operation-history access

#### Scenario: Launcher starts from operation history

- **GIVEN** an authenticated operator can launch Ansible playbooks
- **WHEN** the operator uses the launch affordance on `/ansible/operations`
- **THEN** the UI SHALL navigate to device inventory for an explicit target selection
- **AND** it SHALL NOT open a targetless `/ansible/launch` dead end

#### Scenario: View-only operator browses operations

- **GIVEN** an authenticated operator has `ansible.runs.view` but not `ansible.runs.launch`
- **WHEN** the operator opens `/ansible/operations`
- **THEN** canonical operation history SHALL render
- **AND** no launch affordance SHALL be shown

#### Scenario: Northbound-only viewer opens device details

- **GIVEN** an authenticated operator has `northbound.actions.view` and does not have `ansible.runs.view`
- **WHEN** the operator opens device details
- **THEN** generic Action History SHALL contain only non-Ansible provider invocations
- **AND** `northbound.actions.view` SHALL NOT grant access to canonical Ansible operation history

#### Scenario: Ansible viewer opens device details

- **GIVEN** an authenticated operator has `ansible.runs.view` and does not have `northbound.actions.view`
- **WHEN** the operator opens an AWX-managed device
- **THEN** canonical Ansible operation history SHALL render
- **AND** the generic Action History SHALL NOT render merely because the actor can view Ansible operations

#### Scenario: Settings manager has one resource permission

- **GIVEN** an authenticated administrator has exactly one of `ansible.controllers.manage` or `ansible.repositories.manage`
- **WHEN** the administrator opens `/settings/ansible`
- **THEN** only the permitted resource tab and controls SHALL render
- **AND** every event SHALL refresh current authority and check the permission for its actual resource
- **AND** a repository manager SHALL NOT gain controller mutation authority from the shared page gate

### Requirement: Disconnected Ansible Mounts Are Inert

Ansible LiveViews SHALL NOT read database-backed Ansible records, device records, or credential references during disconnected mount.

#### Scenario: Static HTTP render precedes LiveView connection

- **WHEN** catalog, launch, or Ansible settings performs its disconnected mount
- **THEN** it SHALL initialize a safe empty state without database-backed resource reads
- **AND** authorized data SHALL load only after the LiveView socket connects
- **AND** settings SHALL refresh current authority before loading resource-specific data
