## ADDED Requirements

### Requirement: Agent-managed edge component identities
The system SHALL require an enrolled host agent for new managed NATS leaf and collector installations and SHALL bind distinct component identities to server-authorized assignments on that host.

#### Scenario: A host manages a leaf and two collectors
- **WHEN** an enrolled host installs a NATS leaf and two supported collectors
- **THEN** each component receives its own identity and private key
- **AND** the leaf uses separate upstream client and local server credentials
- **AND** issuer and account signing keys remain on the trusted control plane

#### Scenario: An agent requests another host's identity
- **WHEN** an agent submits a CSR for a component it is not authorized to manage
- **THEN** issuance is denied without changing that component's current credentials

### Requirement: Managed certificate rotation
The host agent SHALL renew managed component certificates before expiry, install them atomically, and invoke the registered service's supported reload or restart operation. Routine rotation SHALL retire the predecessor only after successor installation and use are confirmed.

#### Scenario: Rotation response or installation is interrupted
- **WHEN** a renewal response is lost or the agent stops during installation
- **THEN** restart recovery retains or restores a usable valid certificate bundle
- **AND** unconfirmed issuance alone does not revoke the predecessor

### Requirement: Durable receiver-side revocation
The system SHALL persist certificate and component revocations and enforce them at all applicable NATS, core, and agent-gateway trust boundaries, independently of cooperation from the revoked component. Revocation SHALL block renewal and reconnect and terminate affected active sessions within the approved online enforcement bound.

#### Scenario: Revoke one leaf while another remains connected
- **WHEN** an administrator revokes one leaf identity
- **THEN** its existing hub sessions terminate and its reconnect and renewal attempts fail
- **AND** an unaffected leaf continues delivering telemetry
- **AND** receiver restarts or failover do not restore the revoked identity

#### Scenario: Revoke a core or gateway server certificate
- **WHEN** an administrator revokes an issued core or gateway server certificate
- **THEN** applicable clients reject that certificate and terminate affected sessions
- **AND** a valid replacement identity can restore authorized service

#### Scenario: A revoked host is offline
- **WHEN** the host agent cannot receive a revocation notification
- **THEN** reachable hub enforcement points still apply the revocation
- **AND** the UI shows outstanding edge enforcement rather than reporting completion
- **AND** local ingestion may continue under the last verified policy only for the enrolled local leaf endpoint and identity, with stale policy reported
- **AND** ordinary TLS validation and certificate expiry remain enforced
- **AND** fresh policy applies revocations and the hub checks current policy on reconnect

#### Scenario: Scheduled hub grant expiry
- **WHEN** an authorized client or leaf reaches its broker-enforced grant expiry
- **THEN** its client library reconnects and restores subscriptions using fresh authorization
- **AND** acknowledged, deduplicated JetStream publications and a durable consumer retain their progress without lost or duplicate stored records
- **AND** the nominal grant lifetime defaults to 12 hours, is configurable, receives +/-20% jitter, and never exceeds certificate expiry

#### Scenario: All hub authorizers disappear
- **WHEN** no hub authorizer remains available
- **THEN** the broker still expires existing grants within the configured lifetime plus its maximum jitter
- **AND** new connections cannot obtain authorization
- **AND** ordinary revocation or de-adoption uses targeted disconnects without waiting for that expiry

### Requirement: Hub session grant convergence
The hub authorizer SHALL name each grant it issues by the certificate fingerprint and a digest of the permissions the grant carries. It SHALL disconnect an admitted hub session whose broker-reported grant name differs from the grant the presented certificate would receive now, so the session reconnects under the current grant within a bounded number of policy refreshes rather than at grant expiry. A session whose grant is current SHALL NOT be disconnected. Admission SHALL be unchanged.

#### Scenario: A session holds a grant other than the current grant
- **WHEN** a hub session was granted under an earlier static identity list, an earlier stored grant, an earlier release's unnamed grant, or by another authorizer replica with a different view
- **THEN** a later presented-certificate scan disconnects that session
- **AND** its reconnect receives the current grant
- **AND** sessions of the same certificate holding the current grant stay connected

#### Scenario: A rolling upgrade or a disagreeing authorizer
- **WHEN** many sessions hold a grant other than the current grant
- **THEN** each scan disconnects a bounded number of them
- **AND** a certificate whose reconnect returns with the same grant is not disconnected again for that grant until a retry window passes

#### Scenario: The static identity list has not been read
- **WHEN** an authorizer has not yet read the configured static identity list
- **THEN** it refuses an admitted infrastructure certificate rather than granting its stored permissions
- **AND** host-enrolled components are granted as before
- **AND** the scan disconnects no admitted session for its grant

#### Scenario: The database is unavailable during a policy refresh
- **WHEN** a configuration or policy read fails
- **THEN** the authorizer keeps its last snapshot, static identity list and tracked sessions
- **AND** a stale snapshot stops admitting new connections by its own freshness bound

### Requirement: Operator certificate lifecycle controls
The UI SHALL expose certificate identity, host binding, expiry, renewal health, and scoped Revoke, Rotate, and Re-enroll actions with authorization, audit, and distinct requested/enforced/failed states.

#### Scenario: Enforcement fails after the revocation is recorded
- **WHEN** a revocation is persisted but an enforcement point does not acknowledge it
- **THEN** the UI reports the outstanding or failed enforcement
- **AND** a database status update alone does not mark revocation complete

### Requirement: Authentication-mode-aware onboarding
The CLI SHALL check the deployment's NATS authentication mode and required account readiness before onboarding. It SHALL provision component access through the control plane without silently creating deployment accounts or distributing account signing seeds to edge hosts.

#### Scenario: Static mTLS deployment has no JWT signer
- **WHEN** an authorized operator installs a managed leaf or collector in static mTLS mode
- **THEN** onboarding uses the supported mTLS identity path
- **AND** it does not require a JWT account seed

#### Scenario: JWT account setup is incomplete
- **WHEN** onboarding targets a JWT deployment without its configured account signer or resolver
- **THEN** preflight identifies the missing deployment setup before partial component installation
- **AND** account bootstrap remains an explicit privileged operation
