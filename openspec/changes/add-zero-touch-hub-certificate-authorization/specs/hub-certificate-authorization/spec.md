## ADDED Requirements

### Requirement: Chart identities are adopted without operator action
On a chart install, core SHALL adopt the NATS client certificate of every identity the chart defines from a public certificate inventory the chart publishes, and SHALL NOT require an operator to submit those certificates.

#### Scenario: An install is upgraded to a release with the inventory
- **WHEN** core starts with the chart's public certificate inventory mounted
- **THEN** each inventory certificate that chains to the deployment root, is valid, is not revoked and carries a chart identity's subject is recorded as adopted
- **AND** no administrator API call was made

#### Scenario: Certificates are regenerated
- **WHEN** the chart regenerates its certificates and the inventory changes
- **THEN** core records each new certificate as the successor of the component with that subject
- **AND** the client presenting it is admitted without operator action

#### Scenario: A certificate does not belong to the install
- **WHEN** the inventory contains a certificate that does not chain to the deployment root or whose subject is not a chart identity
- **THEN** core does not adopt it and reports it with the reason

#### Scenario: The inventory holds no secrets
- **WHEN** the chart renders or generates the inventory
- **THEN** it contains public certificates only and no private key or CA key

### Requirement: Signing keys are created by the install, not pasted by an operator
On a chart install, the callout signing keys SHALL be generated once by the chart, with the seeds available only to core and the public keys delivered to the broker without an operator copying them into values.

#### Scenario: Enforcement is turned on
- **WHEN** an operator sets the enforcement value and no other certificate authorization value
- **THEN** the broker is configured with the public keys and core's authorizer authenticates with the seeds

#### Scenario: The generator runs again
- **WHEN** the generator runs on an install that already has signing keys
- **THEN** the keys are unchanged

#### Scenario: Stored and mounted keys disagree
- **WHEN** core finds signing keys both in its database and mounted, and they differ
- **THEN** core reports the conflict and answers no authorization request

### Requirement: Hub readiness is reported before a leaf is installed
The system SHALL report whether the hub can accept a leaf, and the CLI SHALL show it and SHALL NOT change an edge host when the hub cannot.

#### Scenario: An operator checks the hub
- **WHEN** an operator runs the hub status command with the CLI's edge scope
- **THEN** it shows whether enforcement is active, how many chart identities are adopted and which are not, and whether a leaf listener is configured

#### Scenario: A leaf install is attempted against a hub that cannot accept it
- **WHEN** the hub reports enforcement off, no leaf listener, or an unadopted chart identity
- **THEN** the leaf install command stops before installing a package or writing a file
- **AND** it names the cause and the setting that resolves it

### Requirement: Enabling enforcement does not strand chart clients
Turning enforcement on SHALL NOT require any prior manual step for chart identities, and turning it off SHALL return the install to static certificate authorization.

#### Scenario: Enforcement is enabled on a running install
- **WHEN** enforcement is turned on after core has reported every chart identity adopted
- **THEN** every chart client reconnects and none is refused

#### Scenario: Enforcement is disabled
- **WHEN** the enforcement value is set back to off
- **THEN** chart clients connect by static certificate mapping as before
