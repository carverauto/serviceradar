## ADDED Requirements

### Requirement: Ansible automations in settings
The Ansible settings UI SHALL expose automation management beside controller and repository management: catalog entries, automation creation from a repository playbook, the provisioning plan and progress, owned-object state and drift, and retirement, each guarded by the exact permission for that action.

#### Scenario: Create and provision an automation
- **GIVEN** an administrator with the provisioning permission
- **WHEN** they choose a playbook, declare or accept its inputs and choose the referenced inventory, execution environment and credential from the controller's existing objects
- **THEN** the UI SHALL show the plan of objects to be created before any is created
- **AND** after confirmation SHALL show per-object progress and the pending review of each owned template

#### Scenario: Provisioned automation awaits review
- **WHEN** an automation's generation is provisioned and its binding is not approved
- **THEN** the UI SHALL show it as awaiting review and SHALL NOT offer launch

#### Scenario: Drift is shown
- **WHEN** an owned object is drifted or missing
- **THEN** the automation SHALL show the state and the changed fields
- **AND** SHALL offer only replace and release for a job template, and only release for a project

#### Scenario: Operator without the provisioning permission
- **WHEN** a user without the provisioning permission opens Ansible settings
- **THEN** automation mutation controls SHALL NOT be offered
- **AND** a forged mutation event SHALL be refused

### Requirement: Membership review page
The web UI SHALL provide a page that lists AWX host memberships by controller, inventory or device, including non-current rows, with disposition, address and evidence, and that offers approval and quarantine release to authorized human principals.

#### Scenario: Review proposed memberships
- **WHEN** an authorized principal opens the page for an inventory
- **THEN** proposed memberships SHALL be listed with the device they would link and the evidence
- **AND** each SHALL offer approval

#### Scenario: Duplicate or stale rows
- **WHEN** a device has more than one membership row
- **THEN** the page SHALL show every row and mark which are current
- **AND** SHALL NOT present a non-current row as usable

### Requirement: Readiness at the point of launch
The launch page and the device Ansible panel SHALL show each selected device's readiness reason and remedy instead of a generic not-ready message, and SHALL show the panel for a device that is not yet in AWX inventory.

#### Scenario: Mixed readiness in a selection
- **WHEN** an operator selects several devices for an automation
- **THEN** each device SHALL show launchable or its specific reason with a link to the remedy
- **AND** the operator SHALL be able to proceed with only the launchable devices

#### Scenario: Device not in AWX inventory
- **WHEN** an operator opens the Ansible panel of a device that no AWX host links to
- **THEN** the panel SHALL say so and name the controllers that were checked

### Requirement: Binding renewal from the automation
The web UI SHALL let an authorized human principal review and renew an automation's binding from the automation, showing the revision's commit, content digest, inputs, referenced objects and live readback, and for a new revision the differences from the approved one.

#### Scenario: Renew an expired approval with unchanged evidence
- **GIVEN** an automation whose approval expired and whose live state still matches the revision
- **WHEN** the principal renews
- **THEN** the review SHALL present the unchanged evidence for confirmation
- **AND** SHALL NOT require re-entering identifiers, digests or the input schema
