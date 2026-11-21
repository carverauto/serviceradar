## ADDED Requirements

### Requirement: A leaf is deployed with one token issued from the UI
The system SHALL let an operator issue a leaf onboarding token for an edge site from the web UI, and the CLI SHALL deploy the leaf on an enrolled host from that token alone, without an operator login on the host.

#### Scenario: An operator deploys a leaf
- **WHEN** an operator issues a leaf token on an edge site page and runs the shown command on a host with an enrolled agent
- **THEN** the leaf is registered for that site, its certificates are issued through the host's agent, and the leaf service is started
- **AND** no operator credential was entered on the host

#### Scenario: The token is presented from another host after binding
- **WHEN** a leaf token that has already registered a leaf is presented naming an agent id other than the one stored on its onboarding package at the first successful registration, including the same host after its agent identity changed in a reinstall
- **THEN** it is refused and the attempt is recorded as a security event

#### Scenario: The same host resumes an interrupted install
- **WHEN** a leaf token that has already registered a leaf is presented again naming the agent id stored on its onboarding package at the first successful registration, for the same site, before it expires or is revoked and before the leaf is reported active
- **THEN** registration succeeds without creating a second leaf, and the token authorizes requesting issuance for, and reading the status of, that leaf

#### Scenario: The leaf is active
- **WHEN** a leaf token is presented after its leaf has been reported active
- **THEN** it is refused

#### Scenario: The token is expired or revoked
- **WHEN** an expired or revoked leaf token is presented
- **THEN** it is refused and nothing on the site changes

#### Scenario: A first attempt fails before registration
- **WHEN** a leaf token is presented while the hub cannot accept a leaf or the host has no enrolled agent
- **THEN** the command stops with the reason
- **AND** the same token can be used again once the cause is resolved

### Requirement: A leaf token grants no more than one leaf install
A leaf onboarding token SHALL authorize only reading its edge site and hub readiness, registering one leaf for that site on an enrolled host agent, and requesting that leaf's certificates and reading its status, SHALL be bound to the agent id stored on its onboarding package at its first successful registration, and SHALL NOT carry or return private key material.

#### Scenario: A leaf token is presented to the agent package download or bundle route
- **WHEN** a leaf token is presented to the existing onboarding package download or bundle route
- **THEN** the request is refused and recorded as a security event
- **AND** the leaf package is not spent, no join token or bundle is returned, and no operator actor is created

#### Scenario: A leaf token is redeemed
- **WHEN** a leaf token is redeemed on the leaf redemption route
- **THEN** the actor it yields is scoped to its one site and the one component it registers
- **AND** the package moves only through bind and complete, never to delivered

#### Scenario: The token is used against another site
- **WHEN** a leaf token for one site is presented for a different site or any other edge resource
- **THEN** the request is refused

#### Scenario: The host has no enrolled agent
- **WHEN** a leaf token is presented by a client that names no enrolled agent with a live gateway session
- **THEN** no leaf is registered

#### Scenario: Keys stay on the host
- **WHEN** a leaf is deployed from a token
- **THEN** its private keys are generated on the host and no response to the token contains a private key

### Requirement: There is one leaf deployment path
The system SHALL deploy leaves only through agent-managed registration and SHALL NOT offer a downloadable leaf bundle, a leaf setup script, or server-generated leaf private keys. The UI SHALL offer issuing a leaf token as its deployment action. The CLI SHALL also accept an operator login in place of a leaf token for the same managed install.

#### Scenario: An operator opens an edge site
- **WHEN** an operator views an edge site in the UI or the CLI
- **THEN** no leaf bundle download, setup script or server-generated key is offered
- **AND** the UI offers issuing a leaf token as the deployment action

#### Scenario: Automation installs a leaf with an operator login
- **WHEN** `edge install leaf` is run with an operator login instead of a leaf token
- **THEN** the leaf is installed through the same agent-managed registration

### Requirement: Leaf and site status reflect the hub connection
The system SHALL report a leaf as connected only while its recorded certificate has a live session on the hub, and SHALL derive the site's active or offline state from it.

#### Scenario: A leaf connects
- **WHEN** a deployed leaf establishes its first hub session
- **THEN** the leaf server moves from pending to connected, with no provisioned state between them
- **AND** the leaf is shown as connected and its site as active

#### Scenario: A leaf stops
- **WHEN** a leaf's hub session has been absent for a full scan interval
- **THEN** the leaf is shown as disconnected and its site as offline

#### Scenario: A leaf reconnects
- **WHEN** a leaf that was connected has been marked disconnected and its site offline, and its hub session returns
- **THEN** the leaf server moves from disconnected to connected
- **AND** the site returns to active through the come_online transition

#### Scenario: The hub cannot be observed
- **WHEN** core's hub authorizer is not connected
- **THEN** leaf status is shown as unknown

### Requirement: A site is not created with an unconfigured hub address
The system SHALL refuse to create an edge site or issue a leaf token when the install has no configured address for leaves to dial, SHALL NOT substitute a default address, and SHALL refresh the site's stored hub address from configuration when a leaf token is issued.

#### Scenario: The install has no leaf address
- **WHEN** an operator tries to create an edge site or issue a leaf token on an install with no configured leaf address
- **THEN** the action is refused with a message naming the missing setting

#### Scenario: A site was created under the old default address
- **WHEN** a leaf token is issued for a site whose stored hub address is the former hard-coded default and the install now has a configured leaf address
- **THEN** the site's stored hub address is replaced with the configured address before the token is returned

### Requirement: A leaf has least privilege on the hub
The hub SHALL grant a leaf only the subjects an edge site needs, and SHALL refuse it any other subject.

#### Scenario: An edge collector sends data through the leaf
- **WHEN** an edge collector publishes its data and reads its rule bundle through the leaf
- **THEN** the hub accepts both

#### Scenario: The leaf reaches outside its grant
- **WHEN** a leaf publishes or subscribes to a hub subject outside its grant
- **THEN** the hub refuses it
