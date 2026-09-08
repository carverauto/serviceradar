## ADDED Requirements

### Requirement: Credential Broker Resolution for Inventory Plugins
The plugin runtime SHALL resolve credential-broker grants into the secret material an inventory plugin requires before plugin invocation, and SHALL refresh grant-derived material before expiry. A plugin assignment whose credentials are broker-managed MUST NOT fail with missing-credential errors while valid grants exist for it. Plugin artifact download tokens SHALL be refreshed as part of config delivery so token expiry cannot permanently break plugin execution.

#### Scenario: Proxmox inventory plugin consumes a broker grant
- **GIVEN** a policy-materialized assignment of the Proxmox inventory plugin with a credential-broker grant for the Proxmox API token
- **WHEN** the agent executes the plugin
- **THEN** the runtime resolves the grant to the API token and the plugin authenticates to the Proxmox API
- **AND** the grant resolution is recorded in the credential resolution audit

#### Scenario: Expired grant is refreshed, not fatal
- **GIVEN** an assignment whose embedded grant material has expired
- **WHEN** the next config delivery or plugin execution occurs
- **THEN** fresh grant material is obtained and the plugin executes successfully

#### Scenario: Stale artifact download token recovers
- **GIVEN** an agent holding an expired plugin artifact download token
- **WHEN** config delivery succeeds
- **THEN** the agent receives a fresh download token and subsequent artifact fetches succeed
