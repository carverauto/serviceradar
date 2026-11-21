## ADDED Requirements

### Requirement: Chart identities are adopted without operator action
On a chart install, core SHALL adopt chart identities' NATS client certificates from a public certificate inventory the chart publishes by one ordered rule: first, while any infrastructure certificate row lacks a stored subject, core SHALL adopt nothing and SHALL report that state with the remedy; otherwise, for each qualifying certificate whose subject is not held, core SHALL create the component and record the certificate. Core SHALL report every chart identity that is not adopted with the reason, and SHALL NOT require an operator to submit those certificates. A subject is held when any recorded certificate, on any component and whether or not it is revoked or superseded, carries that subject; recorded certificates SHALL store their subject whenever they are recorded. A chart identity is a subject for which the chart's certificate generator issues a distinct NATS client certificate. A static user whose certificate file is a copy of another identity's certificate (`serviceradar-flowgger`, `serviceradar-otel`, `serviceradar-netflow-collector`) and the `O=ServiceRadar` static user are not chart identities: they SHALL NOT be counted in adoption coverage and SHALL NOT block a leaf install.

#### Scenario: Alias and organization users are not chart identities
- **WHEN** core reports adoption coverage on a chart install
- **THEN** `serviceradar-flowgger`, `serviceradar-otel`, `serviceradar-netflow-collector` and `O=ServiceRadar` are neither counted nor listed as not adopted
- **AND** a leaf install is not stopped on their account

#### Scenario: An install is upgraded to a release with the inventory
- **WHEN** core starts with the chart's public certificate inventory mounted, no infrastructure certificate row lacks a stored subject, a chart identity's subject is not held, and the inventory holds a certificate for it that chains to the deployment root, is valid, is not revoked, and whose subject is present in the static users file
- **THEN** core creates the component, with a component id derived from the subject only and that subject's static grant as its stored permissions, and records the certificate with its subject
- **AND** no administrator API call was made

#### Scenario: An adopted certificate is regenerated
- **WHEN** the chart regenerates a chart identity's certificate whose predecessor was adopted
- **THEN** the replacement is recorded by the existing runtime certificate rotation path, not by the inventory
- **AND** the inventory writes nothing for that subject because it is held
- **AND** once the static users file has been read, the client presenting the recorded replacement is admitted without operator action
- **AND** while the static users file is missing or unread, the chart identity is still refused

#### Scenario: A revoked chart identity is regenerated
- **WHEN** a chart identity's certificate was revoked and the chart then regenerates a replacement for that subject
- **THEN** neither the rotation path nor the inventory records the replacement, and no second component is created for the subject
- **AND** core reports the subject in chart identity coverage with the reason
- **AND** the client presenting the replacement stays refused until an operator acts

#### Scenario: A regenerated certificate's subject is not held
- **WHEN** the chart regenerates its certificates, no infrastructure certificate row lacks a stored subject, and a chart identity's subject is not held
- **THEN** core adopts the inventory certificate for that subject only if it chains to the deployment root, is valid, is not revoked, and its subject is a chart identity present in the static users file
- **AND** a certificate that fails any of these checks is reported with the reason and nothing is written

#### Scenario: A rotation names an unrecorded predecessor
- **WHEN** the rotation manifest names a predecessor that was never recorded while an older certificate of that subject is recorded
- **THEN** neither the rotation path nor the inventory records the current certificate
- **AND** core reports the chart identity as not adopted with that reason

#### Scenario: Legacy certificate rows have no subject
- **WHEN** any infrastructure component has a recorded certificate without a stored subject
- **THEN** the inventory adopts nothing
- **AND** core reports that state with the remedy: record those certificates again through the existing adoption API, or remove the component

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
The system SHALL report whether the hub can accept a leaf, and the CLI SHALL show it. The leaf install command SHALL NOT change an edge host when the hub cannot accept a leaf or its status cannot be read; collector installs keep their current behaviour.

#### Scenario: An operator checks the hub
- **WHEN** an operator runs the hub status command with the CLI's edge scope
- **THEN** it shows whether enforcement is configured, whether core's authorizer is answering, how many chart identities are adopted and which are not, whether the hub broker's leaf listener is configured, and whether the leaf upstream URL for this install is configured

#### Scenario: A leaf install is attempted against a hub that cannot accept it
- **WHEN** the hub status is missing or unreadable, or reports enforcement not configured, the authorizer not answering, no leaf listener, no configured leaf upstream URL, or an unadopted chart identity
- **THEN** the leaf install command stops before installing a package or writing a file
- **AND** it names the first cause that applies, checked in the order status readable, enforcement configured, authorizer answering, leaf listener, leaf upstream URL, chart identity adoption
- **AND** it names the resolver for that cause: wait and retry and check core's health for a missing or unreadable status, `nats.certificateAuthorization.enabled` for enforcement not configured, wait and retry and check core's health (with the readiness reason) for an authorizer not answering, `nats.leafnodes.enabled` for a missing leaf listener, the install's leaf host setting for a missing leaf upstream URL, and the per-subject reason for an unadopted chart identity

#### Scenario: The leaf upstream URL is unset
- **WHEN** no leaf upstream URL is configured for the install and only the built-in hosted fallback address is available
- **THEN** the hub reports the leaf upstream URL as not configured

### Requirement: Enabling enforcement does not strand chart clients
On an install where core reports every chart identity adopted, turning enforcement on SHALL NOT require any prior manual step for chart identities, and turning it off SHALL return the install to static certificate authorization. In three cases an operator must act before enforcement is turned on: an infrastructure certificate row lacks a stored subject, a rotation names an unrecorded predecessor, or a chart identity's subject is revoked. The hub status SHALL show each of these before enforcement is turned on.

#### Scenario: Enforcement is enabled on a running install
- **WHEN** enforcement is turned on after core has reported every chart identity adopted, with no infrastructure certificate row lacking a stored subject, no rotation naming an unrecorded predecessor, and no revoked chart identity subject
- **THEN** every chart client reconnects and none is refused

#### Scenario: Enforcement is enabled while an operator action is pending
- **WHEN** enforcement is turned on while core reports an infrastructure certificate row without a stored subject, a rotation naming an unrecorded predecessor, or a revoked chart identity subject
- **THEN** the affected chart clients stay refused until an operator acts
- **AND** the hub status showed that state before enforcement was turned on

#### Scenario: Enforcement is disabled
- **WHEN** the enforcement value is set back to off
- **THEN** chart clients connect by static certificate mapping as before
