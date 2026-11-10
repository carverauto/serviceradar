## ADDED Requirements

### Requirement: Repositories resolve to reviewed commits
Repository synchronization SHALL record the commit it resolved and a SHA-256 digest for every playbook file at that commit, and SHALL expose both so that an automation can pin an exact revision.

#### Scenario: Repository is synchronized
- **WHEN** a registered repository is synchronized
- **THEN** the resolved commit and the digest of each playbook file SHALL be stored and readable through the API

#### Scenario: Branch moves after a revision was created
- **GIVEN** an automation revision pinned to a commit
- **WHEN** the repository's branch later resolves to a different commit
- **THEN** the existing revision SHALL keep its commit and digests
- **AND** using the new commit SHALL require a new revision

### Requirement: Automations are immutable reviewed descriptions
ServiceRadar SHALL represent each launchable playbook as an automation whose revisions are immutable and name a repository, an exact commit, one playbook path per variant, a content digest, a typed input schema and references to one inventory, one digest-pinned execution environment and one machine credential on one controller.

#### Scenario: Create an automation from a registered repository
- **GIVEN** a synchronized repository and an authorized human principal
- **WHEN** the principal selects a playbook and the referenced controller objects
- **THEN** ServiceRadar SHALL store a revision carrying the commit, content digest, input schema and references
- **AND** SHALL NOT create or change any AWX object as a side effect of storing it

#### Scenario: Change an automation
- **WHEN** any part of an automation is changed
- **THEN** ServiceRadar SHALL create a new revision
- **AND** the previous revision SHALL remain unchanged

#### Scenario: Revision names a moving reference
- **WHEN** a revision is submitted with a branch or tag instead of a commit, or with an execution environment not pinned by digest
- **THEN** ServiceRadar SHALL reject it

### Requirement: Typed non-secret automation inputs
An automation revision MUST declare every launch input in a typed schema limited to text, multi-line text, integer, float, single-choice and multiple-choice fields with optional required, default, range, length, pattern and all-or-none constraints, and MUST NOT declare secret fields, connection or magic variables, or the dispatch-marker names.

#### Scenario: Forbidden input is declared
- **WHEN** a schema declares a secret field, a variable beginning with `ansible_`, an inventory or play magic variable, or a dispatch-marker name
- **THEN** ServiceRadar SHALL reject the revision

#### Scenario: Launch supplies an undeclared or invalid value
- **WHEN** a launch supplies an input that is not declared or that violates its constraints
- **THEN** ServiceRadar SHALL reject the launch before any AWX request

#### Scenario: Inputs that belong together
- **GIVEN** a schema with an all-or-none group
- **WHEN** a launch supplies some but not all inputs of the group
- **THEN** ServiceRadar SHALL reject the launch and name the group

### Requirement: Project and job template provisioning from an automation revision
ServiceRadar SHALL provision, for an automation revision, the AWX project for the revision's repository and commit, pinned to that commit with update on launch disabled, and one job template for each combination of the revision's variants and offered run modes whose prompt flags and survey are exactly those the hardened launch contract requires, using only the typed brokered provisioning commands.

#### Scenario: Provision a revision
- **GIVEN** an authorized human principal with the provisioning permission and a controller with a provisioning credential
- **WHEN** the principal provisions a revision
- **THEN** ServiceRadar SHALL create the project when none exists for that repository and commit, and wait until AWX reports the pinned commit as its synchronized revision
- **AND** SHALL create one job template per variant and offered run mode with the referenced inventory, execution environment and machine credential
- **AND** SHALL set on each template a survey containing the dispatch-marker fields and one question per declared input, with free-form variable prompting disabled

#### Scenario: Project synchronizes to a different commit
- **WHEN** AWX reports a synchronized revision other than the pinned commit
- **THEN** provisioning SHALL fail without creating a job template

#### Scenario: Plan before provisioning
- **WHEN** a principal requests the plan for a revision
- **THEN** ServiceRadar SHALL list every object and role grant it would create
- **AND** SHALL NOT mutate AWX

### Requirement: Owned and referenced AWX objects
ServiceRadar SHALL own only the projects, job templates, surveys and role grants it created for an automation, SHALL reference but never create, modify or delete organizations, inventories, hosts, execution environments and credentials, and SHALL NOT grant any role on an object it does not own.

#### Scenario: Role grants for the execution principal
- **WHEN** a generation is provisioned
- **THEN** ServiceRadar SHALL grant the execution principal permission to execute every owned template of the generation and to read the owned project
- **AND** SHALL grant nothing else

#### Scenario: Referenced object is missing or unusable
- **WHEN** a referenced inventory, execution environment or credential does not exist or cannot be used by the provisioning principal
- **THEN** provisioning SHALL fail with a reason naming the reference
- **AND** ServiceRadar SHALL NOT create a substitute

#### Scenario: Hand-built template exists
- **GIVEN** a job template an operator created in AWX
- **WHEN** automations are provisioned on the same controller
- **THEN** ServiceRadar SHALL NOT modify, adopt or delete that template
- **AND** its existing reviewed binding SHALL keep working

### Requirement: Immutable generations
ServiceRadar MUST provision new job templates for every new revision, MUST use one project per repository and commit that every generation at that commit references, and MUST NOT edit an owned job template, survey or project after it has been provisioned.

#### Scenario: New revision of an automation with an approved binding
- **GIVEN** an automation whose current generation has an approved binding
- **WHEN** a new revision is provisioned
- **THEN** the existing generation and its binding SHALL remain usable
- **AND** the new generation SHALL remain not launchable until its own binding is approved

#### Scenario: New revision at an unchanged commit
- **GIVEN** an owned, in-sync project for a repository and commit
- **WHEN** a new revision at the same commit is provisioned
- **THEN** its job templates SHALL reference that project
- **AND** ServiceRadar SHALL NOT create, update or edit a project for it

#### Scenario: Superseded generation
- **WHEN** a newer generation's binding is approved, or the older binding is revoked or expires without renewal
- **THEN** the older generation SHALL become eligible for retirement

### Requirement: Separate provisioning principal
Provisioning MUST use a controller credential whose purpose is distinct from synchronization, execution and callback, and that purpose MUST NOT be able to launch, relaunch or cancel a job, read credential secrets, or reach any AWX endpoint outside the reviewed provisioning mappings.

#### Scenario: Launch attempted with the provisioning purpose
- **WHEN** any component requests a job launch using the provisioning purpose
- **THEN** the request SHALL be refused before credentials are resolved

#### Scenario: Controller has no provisioning credential
- **WHEN** provisioning is requested for a controller without a provisioning credential
- **THEN** the request SHALL fail with a specific reason
- **AND** SHALL NOT fall back to the synchronization, execution or callback credential

#### Scenario: Provisioning credential is in use
- **WHEN** a client deletes a credential referenced as a controller's provisioning credential
- **THEN** the usage guard SHALL reject the deletion and identify the controller

### Requirement: Provisioning yields a prepared review and never an approval
ServiceRadar MUST, after provisioning a generation, read the created objects back with the execution principal and prepare a binding review that takes the content digest and input schema from the automation revision, and MUST NOT approve a binding, approve a membership or launch a job as a consequence of provisioning.

#### Scenario: Provisioning completes
- **WHEN** every object of a generation exists
- **THEN** the automation SHALL show a prepared review awaiting a human principal
- **AND** the automation SHALL NOT be launchable

#### Scenario: Readback differs from the revision
- **WHEN** the objects read back with the execution principal do not match the revision
- **THEN** ServiceRadar SHALL report the difference and SHALL NOT prepare a review

#### Scenario: Reviewer approves
- **GIVEN** a prepared review
- **WHEN** a human principal holding the binding permission approves it through the existing review
- **THEN** the automation SHALL become launchable for approved memberships in the referenced inventory

#### Scenario: Terraform or an API client provisions
- **WHEN** a non-interactive client provisions an automation
- **THEN** the result SHALL expose the pending review reference
- **AND** SHALL NOT approve it

#### Scenario: No approved membership exists for the review
- **WHEN** the referenced inventory has no approved membership for the review to attest against
- **THEN** the automation SHALL say that membership review is required
- **AND** SHALL NOT create or approve a membership

### Requirement: Drift of owned objects is reported and never repaired
ServiceRadar SHALL compare each owned object's live state with the state recorded at provisioning, SHALL report an object as in sync, drifted, missing or unresolved, and SHALL NOT modify a drifted object or adopt its live values.

#### Scenario: Template edited in AWX
- **WHEN** an owned job template is edited outside ServiceRadar
- **THEN** ServiceRadar SHALL mark it drifted and identify the changed fields
- **AND** SHALL NOT restore or accept the change

#### Scenario: Operator replaces a drifted generation
- **WHEN** an authorized principal chooses to replace a drifted or missing generation
- **THEN** ServiceRadar SHALL provision a new generation from the same revision
- **AND** when the drifted or missing object is the project, SHALL create a new project for that commit that later generations at the commit reference, without editing the old one
- **AND** the new generation SHALL require its own review

#### Scenario: Operator releases ownership
- **WHEN** an authorized principal releases a generation
- **THEN** ServiceRadar SHALL revoke its binding and stop managing its job templates, and its project when no other owned generation references it
- **AND** SHALL leave the AWX objects as found

### Requirement: Guarded retirement and deletion of owned objects
ServiceRadar SHALL retire a generation by revoking its binding, removing the role grants it made and deleting the objects it owns, SHALL refuse while a non-terminal operation references the generation, and SHALL never delete an object it does not own.

#### Scenario: Retire a superseded generation
- **GIVEN** a superseded generation with no non-terminal operation
- **WHEN** it is retired
- **THEN** the Execute grant on each of its job templates and the templates SHALL be removed
- **AND** its project and the project's Read grant SHALL be removed only when no other owned template uses the project

#### Scenario: Operation still running
- **WHEN** retirement is requested while an operation referencing the generation is not terminal
- **THEN** ServiceRadar SHALL refuse and identify the operation

#### Scenario: Delete a repository or controller in use
- **WHEN** a client deletes a repository or controller that an automation references
- **THEN** the deletion SHALL be rejected with the referencing automations identified

### Requirement: First-party automation catalog
ServiceRadar SHALL read catalog entries from catalog files in registered repositories at their resolved commit, SHALL ship the public first-party repository location and the commit tested with each release as code defaults, and SHALL treat a catalog entry as a proposal for an automation revision that receives no approval or launch authority from being first-party.

#### Scenario: Install or upgrade the agent package
- **GIVEN** the first-party repository is registered at the tested commit
- **WHEN** an administrator creates an automation from the agent package catalog entry and references an inventory, an execution environment and a machine credential
- **THEN** ServiceRadar SHALL provision one project and one job template per package family and offered run mode, four when both `run` and `check` are offered
- **AND** SHALL grant the execution principal Execute on every one of those templates
- **AND** the launch inputs SHALL be exactly the version, the optional package URL and the optional package SHA-256, with the URL and SHA-256 accepted only together
- **AND** the automation SHALL require binding review before any launch

#### Scenario: Catalog entry declares a forbidden input
- **WHEN** a catalog file declares an input that the input rules forbid
- **THEN** ServiceRadar SHALL reject that entry and report the reason on the repository

#### Scenario: Deployment configured without chart values
- **WHEN** no deployment setting names the first-party repository
- **THEN** ServiceRadar SHALL offer it from its code default
- **AND** SHALL NOT register it without an explicit operator action

### Requirement: Automation provisioning audit
ServiceRadar SHALL record a secret-free audit event carrying the initiating principal for each automation and revision creation, provisioning request, object creation, role grant, provisioning outcome, drift detection, replacement, release and retirement, and for each membership approval, membership release and binding approval.

#### Scenario: Provisioning is audited
- **WHEN** a generation is provisioned
- **THEN** the audit history SHALL show who requested it, each object created with its controller and upstream identity, and the outcome
- **AND** SHALL contain no credential material

#### Scenario: Binding approval is audited
- **WHEN** a human principal approves a binding
- **THEN** an audit event SHALL record the principal, the binding and the automation revision
