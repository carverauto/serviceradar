## ADDED Requirements

### Requirement: A leaf is deployed with one token issued from the UI
The system SHALL let an operator issue a leaf onboarding token for an edge site from the web UI, and the CLI SHALL deploy the leaf on an enrolled host from that token alone, without an operator login on the host.

#### Scenario: An operator deploys a leaf
- **WHEN** an operator issues a leaf token on an edge site page and runs the shown command on a host with an enrolled agent
- **THEN** the leaf is registered for that site, its certificates are issued through the host's agent, and the leaf service is started
- **AND** no operator credential was entered on the host

#### Scenario: The token is used a second time
- **WHEN** a leaf token that has already registered a leaf is presented again
- **THEN** it is refused and the attempt is recorded as a security event

#### Scenario: The token is expired or revoked
- **WHEN** an expired or revoked leaf token is presented
- **THEN** it is refused and nothing on the site changes

#### Scenario: A first attempt fails before registration
- **WHEN** a leaf token is presented while the hub cannot accept a leaf or the host has no enrolled agent
- **THEN** the command stops with the reason
- **AND** the same token can be used again once the cause is resolved

### Requirement: A leaf token grants no more than one leaf install
A leaf onboarding token SHALL authorize only reading its edge site and hub readiness, registering one leaf for that site on an enrolled host agent, and requesting that leaf's certificates, and SHALL NOT carry or return private key material.

#### Scenario: The token is used against another site
- **WHEN** a leaf token for one site is presented for a different site or any other edge resource
- **THEN** the request is refused

#### Scenario: The host has no enrolled agent
- **WHEN** a leaf token is presented by a client that names no enrolled agent with a live gateway session
- **THEN** no leaf is registered

#### Scenario: A host agent was pinned at issue
- **WHEN** a leaf token pinned to one host agent is presented naming another agent
- **THEN** the request is refused

#### Scenario: Keys stay on the host
- **WHEN** a leaf is deployed from a token
- **THEN** its private keys are generated on the host and no response to the token contains a private key

### Requirement: There is one leaf deployment path
The system SHALL deploy leaves only through agent-managed registration and SHALL NOT offer a downloadable leaf bundle, a leaf setup script, or server-generated leaf private keys.

#### Scenario: An operator opens an edge site
- **WHEN** an operator views an edge site in the UI or the CLI
- **THEN** the only deployment action offered is issuing a leaf token

### Requirement: Leaf and site status reflect the hub connection
The system SHALL report a leaf as connected only while its recorded certificate has a live session on the hub, and SHALL derive the site's active or offline state from it.

#### Scenario: A leaf connects
- **WHEN** a deployed leaf establishes its hub session
- **THEN** the leaf is shown as connected and its site as active

#### Scenario: A leaf stops
- **WHEN** a leaf's hub session has been absent for a full scan interval
- **THEN** the leaf is shown as disconnected and its site as offline

#### Scenario: The hub cannot be observed
- **WHEN** core's hub authorizer is not connected
- **THEN** leaf status is shown as unknown

### Requirement: A site is not created with an unconfigured hub address
The system SHALL refuse to create an edge site or issue a leaf token when the install has no configured address for leaves to dial, and SHALL NOT substitute a default address.

#### Scenario: The install has no leaf address
- **WHEN** an operator tries to create an edge site or issue a leaf token on an install with no configured leaf address
- **THEN** the action is refused with a message naming the missing setting

### Requirement: A leaf has least privilege on the hub
The hub SHALL grant a leaf only the subjects an edge site needs, and SHALL refuse it any other subject.

#### Scenario: An edge collector sends data through the leaf
- **WHEN** an edge collector publishes its data and reads its rule bundle through the leaf
- **THEN** the hub accepts both

#### Scenario: The leaf reaches outside its grant
- **WHEN** a leaf publishes or subscribes to a hub subject outside its grant
- **THEN** the hub refuses it
