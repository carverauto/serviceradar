## ADDED Requirements

### Requirement: Signed updater release descriptor
Every published agent release SHALL include, for each supported Linux architecture, an updater binary and a descriptor that names the component kind, version, operating system, architecture, SHA-256 digest and operation set of that binary, signed with a dedicated updater signing key. The signed message SHALL be the fixed context string, a newline, then the exact descriptor bytes. The installed updater SHALL verify the signature over that domain-separated message before parsing the descriptor, and SHALL reject a descriptor that carries a field its schema does not define or omits a required one.

#### Scenario: Release publishes an updater
- **WHEN** an agent release is published
- **THEN** it SHALL include the updater binary, its descriptor and the descriptor signature for each supported Linux architecture
- **AND** the agent release manifest SHALL reference them

#### Scenario: Release whose updater public key does not match the signing secret
- **WHEN** the public key derived from the updater signing secret differs from the key committed in the source tree
- **THEN** the release SHALL fail before publishing

### Requirement: Root-side verification of an updater replacement
The installed updater MUST itself verify a replacement, while running with root privilege, using only the updater public keys compiled into the running binary, and MUST treat every input supplied by its caller as untrusted. The destination path, owner and mode SHALL be fixed by the updater and SHALL NOT be selectable by the caller.

#### Scenario: Valid replacement
- **GIVEN** a candidate binary and a descriptor whose signature verifies with the compiled-in key
- **AND** the descriptor names the updater kind, the host's platform and the candidate's digest
- **WHEN** the unprivileged agent requests a replacement
- **THEN** the updater SHALL install the candidate at the fixed updater path with the fixed owner and mode

#### Scenario: Another component's signature is presented
- **GIVEN** bytes carrying a valid add-on artifact signature or a valid agent release manifest signature
- **WHEN** they are presented as an updater replacement
- **THEN** the updater SHALL reject them
- **AND** the installed updater SHALL be unchanged

#### Scenario: Descriptor carries an undefined field or omits the operation set
- **WHEN** a descriptor whose signature verifies carries a field the descriptor schema does not define, or has no operation set
- **THEN** the updater SHALL reject the replacement
- **AND** the installed updater SHALL be unchanged

#### Scenario: Candidate does not match its descriptor
- **WHEN** the candidate's digest, kind, operating system or architecture differs from the signed descriptor or from the running host
- **THEN** the updater SHALL reject the replacement with a specific reason

#### Scenario: Caller tries to supply the trust anchor
- **GIVEN** the caller sets an environment variable, flag or file intended to supply a verification key
- **WHEN** the updater verifies a replacement
- **THEN** it SHALL use only its compiled-in key

#### Scenario: Caller swaps an input after verification
- **GIVEN** the caller replaces or redirects a staged input while the updater runs
- **WHEN** the updater installs the candidate
- **THEN** it SHALL install exactly the bytes it verified or reject the replacement

### Requirement: Updater rollback protection
The updater MUST accept only a replacement whose version is strictly greater than its own and not lower than a root-owned record of the highest updater version installed on the host. Installing an older updater SHALL be possible only through the operating system package manager acting as root, and no updater operation or package install, forced or not, SHALL lower that record.

#### Scenario: Older or equal updater is presented
- **WHEN** a validly signed updater with a version lower than or equal to the installed updater is presented
- **THEN** the updater SHALL reject it and remain unchanged

#### Scenario: Version between the installed updater and the floor
- **GIVEN** a root operator installed an older package, so the running updater is below the recorded floor
- **WHEN** a validly signed updater newer than the running one but below the floor is presented
- **THEN** the updater SHALL reject it
- **AND** SHALL accept a validly signed updater at or above the floor

#### Scenario: Updater runs below the floor
- **WHEN** the running updater's version is below the recorded floor
- **THEN** it SHALL keep performing its operations
- **AND** SHALL report that it is below the floor
- **AND** the control plane SHALL classify it `outdated` and schedule the normal forward replacement to a published updater at or above the floor

### Requirement: Atomic and interruption-safe updater replacement
The updater SHALL publish a replacement with a single atomic rename of a fully written, correctly owned, correctly labelled file created in the destination directory, and SHALL never write the installed updater in place.

#### Scenario: Replacement is interrupted before publication
- **WHEN** the replacement stops at any point before the rename
- **THEN** the previously installed updater SHALL remain in place and usable
- **AND** the next replacement attempt SHALL remove the leftover temporary file

#### Scenario: Concurrent execution during replacement
- **WHEN** the updater path is executed while a replacement is in progress
- **THEN** the execution SHALL run either the previous updater or the new one, never a partial file

#### Scenario: Security label cannot be preserved
- **WHEN** the new file's security label cannot be made to match the installed updater's label
- **THEN** the updater SHALL abort before the rename and report a specific reason

### Requirement: Candidate self-test before commitment
The running updater MUST execute the verified candidate's self-test from a path the service account cannot execute, and MUST NOT publish a candidate whose self-test fails or times out.

#### Scenario: Candidate cannot run on the host
- **WHEN** the candidate fails to start, reports a version or operation set different from its descriptor, or fails its verification or replacement self-checks
- **THEN** the running updater SHALL refuse the replacement
- **AND** SHALL report a candidate-defect reason

### Requirement: Each released updater can install its successor
The release process SHALL prove, before publishing, that the previous release's updater installs the candidate updater and that the candidate installs a later updater, each invoked by a non-root caller.

#### Scenario: Candidate cannot be installed or cannot install a successor
- **WHEN** either direction of the proof fails
- **THEN** the release SHALL NOT be published

### Requirement: Package operations do not regress the updater
The agent package SHALL deliver its updater as a package-owned payload and SHALL install it to the active updater path only when the active updater is absent or not newer. Package verification SHALL NOT report a self-replaced updater as a modified package file.

#### Scenario: Older package installed over a self-replaced updater
- **GIVEN** a host whose active updater is newer than the one in a package being installed
- **WHEN** the package is installed or reinstalled
- **THEN** the active updater SHALL remain the newer one
- **AND** the install output SHALL say so

#### Scenario: Root operator forces the package's updater
- **WHEN** a root operator runs the documented forced install of the package's updater
- **THEN** the package's updater SHALL become active
- **AND** the recorded version floor SHALL be unchanged

#### Scenario: Fresh install
- **WHEN** the package is installed on a host with no updater
- **THEN** the active updater SHALL be installed from the package payload with the fixed owner and mode
- **AND** SHALL support self-replacement

#### Scenario: Package verification after self-replacement
- **WHEN** the package manager verifies the agent package after the updater replaced itself
- **THEN** verification SHALL report no modified packaged file because of that replacement

### Requirement: Updater and agent version compatibility
The updater SHALL remain compatible with the command lines of every agent release inside the supported upgrade window. An updater newer than the agent SHALL always be acceptable, and the agent SHALL NOT attempt to install an older updater.

#### Scenario: Agent release is rolled back
- **WHEN** an agent release is rolled back after the updater was replaced
- **THEN** the newer updater SHALL remain installed and serve the older agent

### Requirement: Updater replacement is control-plane driven and stoppable
The control plane SHALL be the only initiator of an updater replacement, SHALL deliver it with the cohort staging of agent release rollouts, and SHALL honour a runtime kill switch stored with the deployment's settings and defaulted in code.

#### Scenario: Replacement follows a healthy agent activation
- **GIVEN** a release rollout whose release carries an updater newer than a target's installed updater
- **WHEN** the target's new agent is confirmed healthy
- **THEN** the control plane SHALL have the agent request the updater replacement
- **AND** SHALL record the outcome on the rollout target

#### Scenario: Agent is current but its updater is not
- **WHEN** an agent already runs the desired release and its updater is replaceable and either older than that release's updater or below its recorded floor
- **THEN** the control plane SHALL schedule a replacement on the rollout's cohort order, to an updater at or above both

#### Scenario: Kill switch is off
- **WHEN** an operator turns the updater replacement setting off
- **THEN** the control plane SHALL dispatch no further replacements
- **AND** installed updaters SHALL keep operating unchanged

#### Scenario: Candidate defect appears in a cohort
- **WHEN** a replacement fails with a candidate-defect reason
- **THEN** the rollout SHALL pause before the next cohort
- **AND** a failure caused by the host environment SHALL be recorded on the target without pausing the rollout

#### Scenario: Deployment without the setting configured
- **WHEN** no setting row exists
- **THEN** the control plane SHALL apply the code default
- **AND** SHALL NOT require a chart value

### Requirement: Updater-owned service properties
The updater SHALL own a managed systemd drop-in for the agent service that declares the service properties its own privileged operations require, SHALL derive its content only from the signed updater binary, and SHALL reconcile it after replacing itself.

#### Scenario: New updater needs a changed service property
- **WHEN** a replacement updater's required properties differ from the installed drop-in
- **THEN** the updater SHALL write the drop-in and reload the service manager
- **AND** the agent SHALL report that a restart is pending until it has restarted

#### Scenario: Caller supplies drop-in content
- **WHEN** the caller attempts to supply or alter the drop-in content
- **THEN** the updater SHALL ignore it

### Requirement: Replaceable updaters are remediated before add-on delivery
The control plane SHALL treat an updater it can replace as remediable: when such an updater lacks an operation an assigned add-on needs, the control plane SHALL replace the updater first and deliver the add-on afterwards.

#### Scenario: Replaceable updater lacks an add-on operation
- **GIVEN** an agent whose updater is `outdated` and lacks an operation an add-on needs
- **WHEN** the add-on is assigned
- **THEN** the control plane SHALL schedule the updater replacement first
- **AND** SHALL deliver the add-on after the operation is reported
