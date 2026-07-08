# Network Credentials

## ADDED Requirements

### Requirement: Plugin credentials are managed from the credential-rules UI
Proxmox, AWX, and UniFi Protect credentials SHALL be created and edited from the
settings/credential-rules page, stored encrypted in the database, with no k8s
secret, hardcoded value, or out-of-band seeding required.

#### Scenario: Create a UniFi Protect api_key rule
- **GIVEN** an operator on the credential-rules page
- **WHEN** they create a rule with provider unifi-protect, auth api_key, the
  controller host, and the api_key value
- **THEN** the credential is stored encrypted and resolvable by the plugin
- **AND** no k8s secret or RPC seeding is required
