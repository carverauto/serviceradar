## ADDED Requirements

### Requirement: Chart identities are adopted without operator action
On a chart install, core SHALL adopt the NATS client certificate of every chart identity from a public certificate inventory the chart publishes, and SHALL NOT require an operator to submit those certificates. A chart identity is a subject for which the chart's certificate generator issues a distinct NATS client certificate. A static user whose certificate file is a copy of another identity's certificate (`serviceradar-flowgger`, `serviceradar-otel`, `serviceradar-netflow-collector`) and the `O=ServiceRadar` static user are not chart identities: they SHALL NOT be counted in adoption coverage and SHALL NOT block a leaf install.

#### Scenario: Alias and organization users are not chart identities
- **WHEN** core reports adoption coverage on a chart install
- **THEN** `serviceradar-flowgger`, `serviceradar-otel`, `serviceradar-netflow-collector` and `O=ServiceRadar` are neither counted nor listed as not adopted
- **AND** a leaf install is not stopped on their account

#### Scenario: An install is upgraded to a release with the inventory
- **WHEN** core starts with the chart's public certificate inventory mounted, no component holds a chart identity's subject, and the inventory holds a certificate for it that chains to the deployment root, is valid, is not revoked, and whose subject is present in the static users file
- **THEN** core creates the component with the static grant for that subject and records the certificate
- **AND** no administrator API call was made

#### Scenario: An adopted certificate is regenerated
- **WHEN** the chart regenerates a chart identity's certificate whose predecessor was adopted
- **THEN** the replacement is recorded by the existing runtime certificate rotation path, not by the inventory
- **AND** the inventory writes nothing for that subject because a component holds it
- **AND** once the static users file has been read, the client presenting the recorded replacement is admitted without operator action
- **AND** while the static users file is missing or unread, the chart identity is still refused

#### Scenario: A revoked chart identity is regenerated
- **WHEN** a chart identity's certificate was revoked and the chart then regenerates a replacement for that subject
- **THEN** neither the rotation path nor the inventory records the replacement, and no second component is created for the subject
- **AND** core reports the subject in chart identity coverage with the reason
- **AND** the client presenting the replacement stays refused until an operator acts

#### Scenario: A regenerated certificate has no component
- **WHEN** the chart regenerates its certificates and no component holds a chart identity's subject
- **THEN** core adopts the inventory certificate for that subject only if it chains to the deployment root, is valid, is not revoked, and its subject is a chart identity present in the static users file
- **AND** a certificate that fails any of these checks is reported with the reason and nothing is written

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
- **THEN** it shows whether enforcement is active, how many chart identities are adopted and which are not, whether the hub broker's leaf listener is configured, and whether the leaf upstream URL for this install is configured

#### Scenario: A leaf install is attempted against a hub that cannot accept it
- **WHEN** the hub reports enforcement off, no leaf listener, no configured leaf upstream URL, or an unadopted chart identity
- **THEN** the leaf install command stops before installing a package or writing a file
- **AND** it names the first cause that applies, checked in the order enforcement, leaf listener, leaf upstream URL, chart identity adoption
- **AND** it names the resolver for that cause: `nats.certificateAuthorization.enabled` for enforcement off, `nats.leafnodes.enabled` for a missing leaf listener while enforcement is on, the install's leaf host setting for a missing leaf upstream URL, and the per-subject reason for an unadopted chart identity

#### Scenario: The leaf upstream URL is unset
- **WHEN** no leaf upstream URL is configured for the install and only the built-in hosted fallback address is available
- **THEN** the hub reports the leaf upstream URL as not configured

### Requirement: Enabling enforcement does not strand chart clients
Turning enforcement on SHALL NOT require any prior manual step for chart identities, and turning it off SHALL return the install to static certificate authorization.

#### Scenario: Enforcement is enabled on a running install
- **WHEN** enforcement is turned on after core has reported every chart identity adopted
- **THEN** every chart client reconnects and none is refused

#### Scenario: Enforcement is disabled
- **WHEN** the enforcement value is set back to off
- **THEN** chart clients connect by static certificate mapping as before
