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
- **AND** with signing material provisioned and the static users file read, the client presenting the recorded replacement is admitted without operator action
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
When the issuer and runtime Secret names match, the chart generator SHALL create the callout signing keys once and backfill missing entries. When the names differ, the issuer Secret owner SHALL provision the three seeds in the issuer Secret and both matching public fragments in the runtime Secret. In that configuration the generator SHALL leave all five entries untouched. The chart SHALL project the seeds only into core and the fragments only into the broker, and only when enforcement is enabled.

#### Scenario: Enforcement is turned on
- **WHEN** an operator sets the enforcement value on an install with provisioned signing material
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
- **WHEN** the hub status is missing or unreadable, or reports enforcement not configured, signing keys not provisioned, the authorizer otherwise not answering, no leaf listener, no configured leaf upstream URL, or an unadopted chart identity
- **THEN** the leaf install command stops before installing a package or writing a file
- **AND** it names the first cause that applies, checked in the order status readable, enforcement configured, all three seeds mounted, authorizer answering, leaf listener, leaf upstream URL, chart identity adoption
- **AND** it names the resolver for that cause: wait and retry and check core's health for a missing or unreadable status, `nats.certificateAuthorization.enabled` for enforcement not configured, provision the missing seeds for `signing keys not provisioned`, check NATS and core health and retry (with the readiness reason) for an authorizer not answering, `nats.leafnodes.enabled` for a missing leaf listener, the install's leaf host setting for a missing leaf upstream URL, and the per-subject reason for an unadopted chart identity

#### Scenario: Core lacks a signing seed
- **WHEN** enforcement is enabled and any of the three seeds is absent from core's mounted files
- **THEN** core starts and hub status shows `signing keys not provisioned`

#### Scenario: NATS lacks a broker fragment
- **WHEN** enforcement is enabled, core has all three seeds, and either required broker fragment is absent
- **THEN** Kubernetes prevents the NATS pod from starting and reports the missing key in its mount error
- **AND** hub status reports the authorizer is not answering and the leaf install directs the operator to check NATS and core health

#### Scenario: The leaf upstream URL is unset
- **WHEN** no leaf upstream URL is configured for the install and only the built-in hosted fallback address is available
- **THEN** the hub reports the leaf upstream URL as not configured

### Requirement: Enabling enforcement does not strand chart clients
With signing material provisioned, when the hub status reports every chart identity adopted, turning enforcement on SHALL NOT require any prior manual step for chart identities and SHALL NOT strand any chart client. A chart identity is adopted when the inventory's certificate for its subject is recorded and not revoked, however it came to be recorded, including by the earlier hand adoption procedure. A chart identity that the hub status reports as not adopted SHALL stay refused after enforcement is on until its reported reason is resolved, whatever the reason; examples are certificate rows without a subject blocking new adoption, a refused or skipped rotation, a revoked subject, and a failed qualification check. The hub status SHALL show every not adopted chart identity with its reason before enforcement is turned on. Turning enforcement off SHALL return the install to static certificate authorization.

#### Scenario: Enforcement is enabled on a running install
- **WHEN** signing material is provisioned and enforcement is turned on after the hub status has reported every chart identity adopted
- **THEN** every chart client reconnects and none is refused

#### Scenario: Hand-adopted certificates are recorded without a subject
- **WHEN** every chart identity's certificate was recorded by the earlier hand adoption procedure, so its rows have no stored subject, and the hub status reports every chart identity adopted
- **AND** signing material is provisioned and enforcement is turned on
- **THEN** every chart client is admitted by its recorded fingerprint
- **AND** the rows without a subject block only new inventory adoption

#### Scenario: Enforcement is enabled while a chart identity is not adopted
- **WHEN** enforcement is turned on while the hub status reports a chart identity as not adopted with a reason
- **THEN** that chart identity's client stays refused until the reported reason is resolved
- **AND** the hub status showed that chart identity and its reason before enforcement was turned on

#### Scenario: Enforcement is disabled
- **WHEN** the enforcement value is set back to off
- **THEN** chart clients connect by static certificate mapping as before
