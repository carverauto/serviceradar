## MODIFIED Requirements

### Requirement: The agent executes AWX command verbs via the awx plugin
The agent SHALL route `awx.*` command verbs to the awx WASM plugin and return its
result, so core-issued AWX REST verbs (launch/list/fetch/cancel) execute. The
agent SHALL also route the read-only `awx.fetch_launch_preflight` verb, which
returns only a typed, redacted projection of the reviewed template and selected
hosts. The control plane SHALL dispatch `awx.launch_job` only after a successful
live preflight has been compared to the approved binding and bound to an
immutable launch snapshot.

#### Scenario: Launch a job template against a host
- **GIVEN** a registered AWX controller bound to an agent that hosts the awx plugin
- **AND** a launchable Playbook backed by an AWX job template
- **AND** a device that is a member of the controller's AWX inventory
- **AND** a successful live launch preflight for the exact template and target
- **WHEN** an authorized operator launches the playbook against that device
- **THEN** the agent invokes the awx plugin's `awx.launch_job` verb
- **AND** AWX launches the job
- **AND** the PlaybookRun advances to `launching` with an `awx_job_id`
- **AND** run pulse populates plays/tasks until a terminal state

## ADDED Requirements

### Requirement: Live AWX launch preflight prevents reviewed-contract drift
The system SHALL obtain a live, redacted AWX preflight through the controller's
assigned edge agent before creating a mutable automation execution or dispatching
`awx.launch_job`. It SHALL compare the live template, survey, project,
inventory, associated credentials, execution environment, launch prompt flags,
and selected host memberships to an immutable, secret-free reviewed launch
snapshot owned by the approved callback binding version using canonical digests
and deny-by-default semantics. It SHALL persist reviewed/live/command digests in
the immutable launch snapshot only after the comparison and a second
authorization read succeed. A digest-only legacy binding SHALL NOT be launchable
until an authorized reviewer creates the reviewed launch snapshot.

#### Scenario: Matching live state permits one launch
- **GIVEN** a user has the required ServiceRadar launch and callback permissions
- **AND** an approved binding fixes the template, project revision, inventory,
  credential IDs, execution environment, survey contract, and prompt policy
- **AND** the exact selected targets have current AwxHostMembership tuples for
  the reviewed controller and inventory
- **WHEN** the user requests a launch
- **THEN** ServiceRadar SHALL dispatch only `awx.fetch_launch_preflight` before
  creating an execution
- **AND** the preflight SHALL be resolved from terminal durable AgentCommand rows
- **AND** the system SHALL write secret-free preflight evidence that has no
  operation or execution foreign key
- **AND** ServiceRadar SHALL re-read the actor, holds, binding, controller, and
  targets before persistence
- **AND** it SHALL persist the reviewed/live/command digests in an immutable
  launch snapshot
- **AND** it MAY then dispatch exactly one `awx.launch_job`

#### Scenario: Template or execution dependency drifts after review
- **GIVEN** an approved binding for a job template
- **AND** the live template, project revision, inventory, credential set,
  execution environment, survey, or prompt policy differs from that binding
- **WHEN** a user requests a launch
- **THEN** the system SHALL reject the request with an operator-safe drift reason
- **AND** it SHALL NOT create an execution, operation, or PlaybookRun
- **AND** it SHALL NOT dispatch `awx.launch_job`
- **AND** it SHALL require authorized binding review before a future launch can
  use the changed configuration

#### Scenario: Target membership is stale or unsafe
- **GIVEN** a selected ServiceRadar device was previously linked to an AWX host
- **AND** the live AWX host is missing, disabled, moved, renamed, or no longer
  belongs to the reviewed inventory
- **WHEN** a user requests a launch
- **THEN** the system SHALL reject the request before execution persistence
- **AND** it SHALL NOT use a host name, address, or inventory returned by AWX to
  broaden the selected target set

#### Scenario: Authorization changes while the preflight is in flight
- **GIVEN** a user starts a launch preflight
- **AND** the user loses a required permission, receives a hold, or the binding
  or target membership changes before the live comparison completes
- **WHEN** ServiceRadar re-reads authorization and policy before persistence
- **THEN** the system SHALL reject the launch
- **AND** it SHALL NOT dispatch `awx.launch_job`

#### Scenario: Edge or AWX read is unavailable
- **GIVEN** a requested launch requires live AWX preflight
- **WHEN** the assigned edge agent is unavailable, the preflight times out, or
  AWX returns a malformed or failed read response
- **THEN** the system SHALL return an operator-safe unavailable/preflight error
- **AND** it SHALL NOT create an execution, operation, or PlaybookRun
- **AND** it SHALL NOT dispatch `awx.launch_job`

### Requirement: AWX execution credentials cannot broaden a user's access
The AWX API credential used by ServiceRadar SHALL be an edge-resolved machine
principal and SHALL never be exposed to a browser, user token, playbook input,
or persistent launch record. ServiceRadar SHALL enforce the requesting user's
RBAC before and after preflight, and the AWX runner role SHALL be limited to
reading reviewed resources and executing approved templates without edit/admin
rights over templates, projects, inventories, credentials, or execution
environments.

#### Scenario: User lacks launch or callback permission
- **GIVEN** a user without a required ServiceRadar launch or callback/CA
  permission
- **WHEN** the user requests a launch or a preflight
- **THEN** ServiceRadar SHALL deny the request before minting a controller grant
- **AND** it SHALL NOT reveal the AWX credential or a live resource projection

#### Scenario: AWX runner cannot modify reviewed resources
- **GIVEN** the ServiceRadar AWX runner machine principal
- **WHEN** it is evaluated against the reviewed controller resources
- **THEN** it SHALL have only the documented read/use/execute permissions needed
  for preflight and approved job launch
- **AND** it SHALL lack permission to modify job templates, projects,
  inventories, credentials, or execution environments
