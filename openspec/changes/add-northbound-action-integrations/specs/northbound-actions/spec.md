## ADDED Requirements

### Requirement: Provider-Neutral Action Catalog
The system SHALL maintain a provider-neutral catalog of executable non-Ansible northbound actions exposed by configured integrations or approved Wasm plugins. Canonical Ansible/AWX launch SHALL remain outside this catalog.

Each action descriptor SHALL include a stable action ID, version, label, description, provider reference, supported scopes, required target context fields, input schema reference or embedded schema, timeout, safety classification, credential requirements, and result schema version.

#### Scenario: Configured provider exposes an action
- **GIVEN** an approved provider exposes a valid action descriptor
- **WHEN** the action catalog is refreshed
- **THEN** the system stores the descriptor with its provider reference and descriptor hash
- **AND** the action can be considered for eligible device, interface, or event targets

#### Scenario: Invalid descriptor is rejected
- **GIVEN** a provider exposes an action descriptor missing required scope or input schema metadata
- **WHEN** the action catalog is refreshed
- **THEN** the descriptor is rejected
- **AND** the provider action is not launchable

#### Scenario: Retained Ansible descriptor is stored
- **GIVEN** a historical northbound provider has type `ansible`
- **AND** one of its descriptors remains stored and enabled
- **WHEN** the operator action catalog is refreshed
- **THEN** the descriptor is excluded from eligible device and interface actions
- **AND** the catalog read does not synchronize new Ansible descriptors
- **AND** the retained provider and descriptor evidence is not deleted

### Requirement: Target Eligibility
The system SHALL determine action eligibility from target scope, required context, provider health, approved capabilities, configured credentials, and the actor's `northbound.actions.launch` permission. Ansible permissions SHALL NOT substitute for provider-neutral action authority.

#### Scenario: Device action is eligible
- **GIVEN** a user selects a device with a primary IP address
- **AND** an enabled provider exposes a device-scoped action requiring `device.ip`
- **AND** the user has permission to launch that action
- **WHEN** the UI asks for eligible actions
- **THEN** the action is returned as launchable

#### Scenario: Missing required context disables an action
- **GIVEN** a user selects an interface without an interface name or external identifier
- **AND** an action requires `interface.name`
- **WHEN** the UI asks for eligible actions
- **THEN** the action is not launchable for that target
- **AND** the reason can be displayed or logged without exposing secrets

#### Scenario: No configured providers disables launch
- **GIVEN** no enabled provider exposes a launchable action for selected devices
- **WHEN** the user views the device list selection toolbar
- **THEN** the Run Action control is disabled
- **AND** launching does not navigate to a provider-specific page that would fail

#### Scenario: User has only Ansible launch authority
- **GIVEN** a user has `ansible.runs.launch` and does not have `northbound.actions.launch`
- **WHEN** the user selects devices in inventory
- **THEN** the provider-neutral Run Action control is not shown
- **AND** the Ansible permission does not make any northbound descriptor eligible

### Requirement: Action Invocation Persistence
The system SHALL persist every northbound action invocation with actor or service principal, source, provider, action ID, descriptor hash, target snapshot, redacted inputs, status, timestamps, result summary, and external correlation ID when available.

#### Scenario: User launches an action
- **GIVEN** a user submits a valid action form for selected devices
- **WHEN** the invocation is accepted
- **THEN** the system stores the invocation and target snapshots before dispatch
- **AND** the invocation status transitions through pending, running, and a terminal state

#### Scenario: Provider returns a per-target result
- **GIVEN** an invocation targets multiple interfaces
- **WHEN** the provider returns mixed per-target results
- **THEN** the system stores each target result separately
- **AND** the invocation summary reflects the aggregate status

#### Scenario: Operator views generic action history
- **GIVEN** a user has `northbound.actions.view`
- **AND** retained invocations exist for Ansible and non-Ansible providers
- **WHEN** the user views generic Action History for a device or interface
- **THEN** the history contains only non-Ansible provider invocations
- **AND** the retained Ansible invocation and target rows remain stored as internal evidence
- **AND** `northbound.actions.view` does not grant access to canonical Ansible operation history

### Requirement: Device and Interface Action Launch
The system SHALL support launching non-Ansible actions from selected devices and selected interfaces using the same provider-neutral invocation model. Device inventory SHALL present this as **Run Action** under `northbound.actions.launch`, separately from canonical **Launch Playbook** under `ansible.runs.launch`.

#### Scenario: Interface action receives device and interface context
- **GIVEN** a user selects a switch interface
- **AND** an NMS action requires `device.ip` and `interface.name`
- **WHEN** the user launches the action
- **THEN** the provider receives both the device context and interface context
- **AND** the invocation history links back to the device and interface

#### Scenario: User has only northbound launch authority
- **GIVEN** a user has `northbound.actions.launch` and does not have `ansible.runs.launch`
- **WHEN** the user selects devices in inventory
- **THEN** Run Action can be shown for eligible non-Ansible descriptors
- **AND** Launch Playbook is not shown
- **AND** the northbound permission does not authorize `/ansible/launch`

### Requirement: Schema-Driven Action Forms
The system SHALL render action launch forms from a constrained schema subset owned by ServiceRadar and SHALL NOT execute provider-supplied UI code.

#### Scenario: Action form renders from schema
- **GIVEN** an action descriptor includes an input schema with text, enum, boolean, and secret reference fields
- **WHEN** the user opens the launch modal
- **THEN** the UI renders ServiceRadar-owned controls for those fields
- **AND** submitted values are validated against the schema before dispatch

#### Scenario: Provider-neutral form opens after Ansible adapter retirement
- **GIVEN** retained Ansible descriptors or metadata exist in storage
- **WHEN** a user opens the provider-neutral Run Action modal
- **THEN** the form renders only the selected non-Ansible descriptor schema
- **AND** it does not render AWX applicability, playbook surveys, git `vars_prompt`, or an Ansible raw `extra_vars` escape hatch

### Requirement: Event Handler Action Execution
The system SHALL allow event handlers to create northbound action invocations after event matching, target resolution, RBAC/service-principal checks, dedupe, cooldown, and optional approval checks.

#### Scenario: Device-down event creates a guarded invocation
- **GIVEN** an enabled event handler matches a device-down event
- **AND** the event resolves to a device target
- **AND** the handler cooldown has expired
- **WHEN** the event is processed
- **THEN** the system creates an action invocation using the handler service principal
- **AND** records the originating event ID on the invocation

#### Scenario: Cooldown suppresses repeated action
- **GIVEN** an event handler has already invoked an action for a device within its cooldown window
- **WHEN** another matching event arrives for the same dedupe key
- **THEN** the system suppresses the invocation
- **AND** emits an observable suppression event

### Requirement: Action Audit Trail
The system SHALL emit audit records and observability events for action descriptor changes, invocation creation, dispatch, completion, failure, cancellation, and event-handler suppression.

#### Scenario: Failed action is auditable
- **GIVEN** a provider fails an invocation
- **WHEN** the failure is stored
- **THEN** an audit record includes actor or service principal, provider, action ID, targets, redacted input summary, and failure classification
- **AND** a normalized observability event is emitted
