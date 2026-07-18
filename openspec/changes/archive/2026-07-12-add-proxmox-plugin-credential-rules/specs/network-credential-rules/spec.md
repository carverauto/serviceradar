## ADDED Requirements

### Requirement: Network-wide credential rule storage
The system SHALL provide deployment-scoped network credential rules for device/API credentials and SHALL store secret material encrypted at rest.

#### Scenario: Save Proxmox API token rule
- **GIVEN** an authorized admin creates a credential rule for `proxmox_pve_api`
- **WHEN** the token ID and token secret are saved
- **THEN** the secret material SHALL be encrypted at rest
- **AND** API/UI reads SHALL return only redacted secret metadata
- **AND** the rule SHALL include provider, auth method, priority, enabled state, SRQL target query, and agent/site scope

#### Scenario: Unauthorized user cannot read secrets
- **GIVEN** a non-admin user reads credential rules
- **WHEN** the response is rendered
- **THEN** raw secret values SHALL NOT be included
- **AND** create, update, test, rotate, and disable actions SHALL be denied unless the user has the required admin permission

#### Scenario: Save SSH private key rule
- **GIVEN** an authorized admin creates a credential rule for SSH console access
- **WHEN** the private key and optional passphrase are saved
- **THEN** the key and passphrase SHALL be encrypted at rest with AshCloak-managed encryption
- **AND** UI/API reads SHALL show only key type, public fingerprint, creation time, rotation metadata, and redacted secret state

### Requirement: Credential rule targeting uses SRQL server-side
The system SHALL evaluate credential rule target queries in the control plane using SRQL and SHALL NOT expose SRQL execution credentials to plugins.

#### Scenario: Preview matched devices
- **GIVEN** a credential rule target query `in:devices vendor_name:Proxmox`
- **WHEN** an admin previews the rule
- **THEN** the system SHALL execute the SRQL query server-side
- **AND** return a count and bounded sample of matching devices
- **AND** return no plaintext credential material

#### Scenario: Plugin receives concrete targets
- **GIVEN** a Proxmox plugin policy references a credential rule
- **WHEN** reconciliation runs
- **THEN** the system SHALL resolve matching devices server-side
- **AND** plugin assignments SHALL include concrete target batches rather than raw SRQL queries

#### Scenario: Auto-discovery opt-in is explicit
- **GIVEN** an admin creates or edits a Proxmox credential rule
- **WHEN** the admin does not enable auto-discovery credential trials
- **THEN** credential broker grants SHALL be limited to devices matched by the rule SRQL target query and edge scope
- **AND** discovered Proxmox-like candidates outside that SRQL result SHALL NOT receive the rule credential

#### Scenario: Auto-discovery opt-in preserves edge scope
- **GIVEN** an admin enables auto-discovery credential trials for a Proxmox credential rule
- **WHEN** the system evaluates discovered Proxmox candidates
- **THEN** broker grants SHALL still be limited by the configured agent, gateway, or partition scope
- **AND** the settings UI SHALL display that the rule is using auto-discovery rather than SRQL-only targeting

### Requirement: Agent-scoped credential broker grants
The system SHALL materialize credential rules as scoped credential references and broker grants only to agents whose scope permits use of the credential for the matched target devices.

#### Scenario: Datacenter-specific Proxmox credentials
- **GIVEN** a credential rule scoped to agent `dc-a-agent`
- **AND** matching Proxmox devices exist in datacenters A and B
- **WHEN** plugin assignments are compiled
- **THEN** only `dc-a-agent` SHALL receive assignments using that rule
- **AND** no agent outside the rule scope SHALL receive the broker grant or credential reference
- **AND** decrypted credential material SHALL NOT be included in plugin assignment payloads or generic command payloads

#### Scenario: Agent scope mismatch blocks assignment
- **GIVEN** a credential rule scoped to edge site `lab-a`
- **AND** a matching device is assigned to an agent in edge site `lab-b`
- **WHEN** reconciliation runs
- **THEN** the credential SHALL NOT be sent to the `lab-b` agent
- **AND** the policy status SHALL report the scope mismatch without exposing the secret

#### Scenario: Credential broker grant constrains runtime use
- **GIVEN** a Proxmox credential test is dispatched to an eligible agent
- **WHEN** the command payload is sent
- **THEN** it SHALL contain a credential broker grant with credential reference, target device, target base URL, allowed methods, allowed API paths, and TTL
- **AND** it SHALL NOT contain `api_token`, password, private key, ticket, cookie, or CSRF token values

### Requirement: Credential precedence and conflict handling
The system SHALL resolve credentials deterministically using provider-compatible precedence rules.

#### Scenario: Per-device override wins
- **GIVEN** a Proxmox device has a per-device Proxmox credential override
- **AND** a network-wide Proxmox credential rule also matches the device
- **WHEN** the Proxmox plugin assignment is compiled
- **THEN** the per-device credential SHALL be selected

#### Scenario: Equal priority conflict is surfaced
- **GIVEN** two enabled Proxmox credential rules with equal priority match the same device and agent scope
- **WHEN** reconciliation runs
- **THEN** the system SHALL NOT try both secrets blindly
- **AND** it SHALL report a credential conflict requiring operator resolution

### Requirement: Credential test execution is brokered and redacted
The system SHALL allow authorized admins to test credential rules through an eligible agent using a credential broker grant while preserving redaction boundaries.

#### Scenario: Test Proxmox credential rule
- **GIVEN** an admin tests a Proxmox credential rule against a matched target
- **WHEN** the selected agent runs the test
- **THEN** the system SHALL report reachability, authentication, TLS, and API-version status
- **AND** the plugin or generic command handler SHALL NOT receive decrypted token material
- **AND** any failure details SHALL redact token, password, cookie, and ticket values

#### Scenario: Test SSH credential rule
- **GIVEN** an admin tests an SSH credential rule against a matched PVE host
- **WHEN** the selected agent runs the test
- **THEN** the system SHALL report reachability, host key verification status, authentication status, and shell availability
- **AND** raw private key, passphrase, and command output SHALL NOT be returned in the test response
