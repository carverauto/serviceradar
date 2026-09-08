## ADDED Requirements

### Requirement: Unified credential settings navigation
The web UI SHALL expose a provider-neutral credentials settings area that replaces Proxmox-specific credential rule entry points as the default operator workflow.

#### Scenario: Credentials page reachable from settings
- **GIVEN** an authenticated admin has credential management permission
- **WHEN** they open Settings
- **THEN** the navigation SHALL include a Credentials entry
- **AND** the page SHALL include separate views for secrets, rules, and consumers

#### Scenario: Legacy network credentials route remains usable
- **GIVEN** an admin navigates to the existing network credential rules route
- **WHEN** unified credential management is enabled
- **THEN** the app SHALL redirect or render the unified credentials experience
- **AND** existing bookmarked Proxmox rule URLs SHALL continue to reach the matching rule edit flow

### Requirement: Credential forms avoid UUID-first workflows
Credential-related forms SHALL ask for the operator-owned secret material or an existing secret selection, not require users to paste internal credential secret UUIDs in the default path.

#### Scenario: AWX controller token setup
- **GIVEN** an admin registers an AWX controller
- **WHEN** they paste an AWX API token
- **THEN** the form SHALL store it as an encrypted credential secret automatically
- **AND** it SHALL associate the controller with that secret

#### Scenario: Existing secret is advanced path
- **GIVEN** an admin already created an encrypted credential secret
- **WHEN** they expand advanced options
- **THEN** they MAY select or paste the existing secret ID
- **AND** validation errors SHALL explain that raw provider tokens belong in the token field
