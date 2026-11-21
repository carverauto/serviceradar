## ADDED Requirements

### Requirement: Chart identities are adopted without operator action
On a chart install, core SHALL adopt chart identities' NATS client certificates from a public certificate inventory the chart publishes by one ordered rule: first, while any infrastructure certificate row lacks a stored subject, core SHALL adopt nothing and SHALL report that state with the remedy; otherwise, for each qualifying certificate whose subject is not held, core SHALL create the component and record the certificate. Core SHALL report every chart identity that is not adopted with the reason, and SHALL NOT require an operator to submit those certificates. Replacements remain with the existing rotation path from `runtime-cert-rotation.json`. A subject is held when any recorded certificate, on any component and whether or not it is revoked or superseded, carries that subject; recorded certificates SHALL store their subject whenever they are recorded. A chart identity is a subject for which the chart's certificate generator issues a distinct NATS client certificate. A static user whose certificate file is a copy of another identity's certificate (`serviceradar-flowgger`, `serviceradar-otel`, `serviceradar-netflow-collector`) and the `O=ServiceRadar` static user are not chart identities: they SHALL NOT be counted in adoption coverage and SHALL NOT block a leaf install.

#### Scenario: Alias and organization users are not chart identities
- **WHEN** core reports adoption coverage on a chart install
- **THEN** `serviceradar-flowgger`, `serviceradar-otel`, `serviceradar-netflow-collector` and `O=ServiceRadar` are neither counted nor listed as not adopted
- **AND** a leaf install is not stopped on their account

#### Scenario: A generated runtime Secret predates an inventory certificate
- **WHEN** the generator runs on upgrade and its runtime Secret lacks a public certificate from core's fixed inventory
- **THEN** the pre-upgrade hook regenerates the runtime certificates and writes the rotation manifest before core rolls

#### Scenario: The supplier provides the runtime Secret
- **WHEN** the install is hosted or the generator is disabled
- **THEN** core projects only the public inventory certificates the supplier lists
- **AND** with the default empty list, core starts, adopts nothing and hub status reports each chart identity as not adopted because no inventory certificate is supplied
- **AND** with a partial list, hub status gives that reason for each omitted identity

#### Scenario: An install is upgraded to a release with the inventory
- **WHEN** core starts with the chart's public certificate inventory mounted, no infrastructure certificate row lacks a stored subject, a chart identity's subject is not held, and the inventory holds a certificate for it that chains to the deployment root, is valid, is not revoked, and whose subject is present in the static users file
- **THEN** core creates the component, with a component id derived from the subject only and that subject's static grant as its stored permissions, and records the certificate with its subject
- **AND** no administrator API call was made

#### Scenario: A held subject has an unrecorded inventory certificate
- **WHEN** a recorded certificate holds the subject and the existing rotation path has not recorded the current inventory certificate
- **THEN** the inventory writes nothing and hub status reports the identity as not adopted because the subject is held and the current inventory certificate is unrecorded
- **AND** hub status directs the operator to the existing successor API and includes a rotation reason only when rotation produced one for that certificate

#### Scenario: A revoked chart identity is regenerated
- **WHEN** a recorded certificate still holds the regenerated certificate's subject after revocation
- **THEN** the inventory writes nothing for that subject

#### Scenario: A regenerated certificate's subject is not held
- **WHEN** the chart regenerates its certificates, no infrastructure certificate row lacks a stored subject, and a chart identity's subject is not held
- **THEN** core adopts the inventory certificate for that subject only if it chains to the deployment root, is valid, is not revoked, and its subject is a chart identity present in the static users file
- **AND** a certificate that fails any of these checks is reported with the reason and nothing is written

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
The chart generator SHALL own the signing set only on non-hosted installs with `certs.generator.enabled` true and matching issuer and runtime Secret names. For a generator-owned set it SHALL provision the three seeds and both matching public fragments together only if all five entries are absent. With all three seeds present it SHALL preserve them and rebuild only missing or stale fragments from them. For any other nonempty signing set it SHALL fail without writing. In every other configuration the Secret supplier SHALL provision the three seeds in the issuer Secret and both matching public fragments in the runtime Secret. Any running generator in those configurations SHALL leave all five entries untouched. The chart SHALL project the seeds only into core and the fragments only into the broker, and only when enforcement is enabled.

#### Scenario: Enforcement is turned on
- **WHEN** an operator sets the enforcement value on an install with the signing seeds present
- **THEN** the chart configures the broker to include the public key fragments
- **AND** core uses the mounted seeds for its authorizer connections

#### Scenario: First provisioning of a generator-owned signing set
- **WHEN** the generator finds none of the five signing entries, including on an upgrade with existing certificates
- **THEN** it writes three new seeds and both matching fragments together on either certificate reconciliation path

#### Scenario: Certificate reconciliation with a generator-owned signing set
- **WHEN** all three seeds are present
- **THEN** the generator preserves every seed and derives each missing or stale fragment from their public keys
- **AND** it leaves all five signing entries unchanged when both fragments already match
- **AND** on either signing outcome the certificate check still determines whether to preserve existing certificates or regenerate them and write the rotation manifest

#### Scenario: A generator-owned signing set has lost seeds
- **WHEN** any signing entry remains and one or more seeds are missing, including when only fragments remain
- **THEN** the job fails without writing and names each missing seed
- **AND** the error directs the operator to restore the missing seeds or deliberately remove all remaining signing entries to provision a new set

#### Scenario: The supplier provides a shared Secret with generation disabled
- **WHEN** a self-managed install uses the same Secret for issuer and runtime certificates and disables the generator
- **THEN** the supplier provisions all five signing entries in that Secret before enabling enforcement

#### Scenario: A previously bootstrapped install upgrades to the chart
- **WHEN** the bootstrap API created a signing record before upgrade and enforcement is enabled with the three chart seeds mounted
- **THEN** core ignores the stored record even if its keys differ
- **AND** core uses the mounted keys for callout responses
- **AND** core logs once that the stored record is unused

### Requirement: Hub readiness is reported before a leaf is installed
The system SHALL report whether the hub can accept a leaf, and the CLI SHALL show it. The leaf install command SHALL NOT change an edge host when the hub cannot accept a leaf or its status cannot be read; coverage warnings SHALL be advisory for the operator and SHALL NOT stop leaf installation. Collector installs keep their current behaviour.

#### Scenario: An operator checks the hub
- **WHEN** an operator runs the hub status command with the CLI's edge scope
- **THEN** it shows whether enforcement is configured, whether core's authorizer is answering, how many chart identities are adopted and which lack coverage (each with a warning and reason), whether the hub broker's leaf listener is configured, and whether the leaf upstream URL for this install is configured

#### Scenario: A leaf install is attempted against a hub that cannot accept it
- **WHEN** the hub status is missing or unreadable, or reports enforcement not configured, signing keys not provisioned, the authorizer otherwise not answering, no leaf listener, or no configured leaf upstream URL
- **THEN** the leaf install command stops before installing a package or writing a file
- **AND** it names the first cause that applies, checked in the order status readable, enforcement configured, all three seeds mounted, authorizer answering, leaf listener, leaf upstream URL
- **AND** it names the resolver for that cause: wait and retry and check core's health for a missing or unreadable status, `nats.certificateAuthorization.enabled` for enforcement not configured, provision the missing seeds for `signing keys not provisioned`, check NATS and core health and retry (with the readiness reason) for an authorizer not answering, `nats.leafnodes.enabled` for a missing leaf listener, and the install's leaf host setting for a missing leaf upstream URL

#### Scenario: Core lacks a signing seed
- **WHEN** enforcement is enabled and any of the three seeds is absent from core's mounted files
- **THEN** core starts and hub status shows `signing keys not provisioned` even if a broker fragment is missing and the authorizer is disconnected

#### Scenario: NATS lacks a broker fragment
- **WHEN** a NATS pod starts with enforcement enabled and either required broker fragment is absent
- **THEN** Kubernetes prevents the affected NATS pod from starting and reports the missing key in that pod's mount error regardless of core's mounted seeds
- **AND** if core keeps answering through a surviving broker, an otherwise ready hub stays ready and leaf install proceeds
- **AND** if core has all three seeds but loses its authorizer connection, hub status reports the authorizer is not answering and leaf install stops before host changes with advice to check NATS and core health

#### Scenario: The leaf upstream URL is unset
- **WHEN** no leaf upstream URL is configured for the install and only the built-in hosted fallback address is available
- **THEN** the hub reports the leaf upstream URL as not configured

### Requirement: Pre-enforcement coverage and broker admission
Hub status SHALL report full coverage when every chart identity's inventory certificate is recorded and unrevoked. Full coverage completes the operator's inventory check before enabling enforcement. A chart identity is adopted when the inventory's certificate for its subject is recorded and not revoked, however it came to be recorded, including by the earlier hand adoption procedure. Hub status SHALL warn about each identity lacking inventory coverage and show the reason before enforcement. Admission SHALL remain with `ServiceRadar.NATS.ManagedCertificateAuthorization` and `ComponentCertificateAuthority.authorize` regardless of inventory coverage. Turning enforcement off SHALL return the install to static certificate authorization.

#### Scenario: Hand-adopted inventory certificates count toward coverage
- **WHEN** an inventory certificate is already recorded and unrevoked from hand adoption
- **THEN** it counts toward coverage even if its legacy row has no stored subject

#### Scenario: The inventory omits a hand-adopted certificate
- **WHEN** an otherwise ready hub enforces authorization and its inventory omits a chart service previously adopted by hand
- **THEN** hub status warns that no inventory certificate is supplied for that identity and leaf installation proceeds

#### Scenario: Enforcement is disabled
- **WHEN** the enforcement value is set back to off
- **THEN** chart clients connect by static certificate mapping as before
