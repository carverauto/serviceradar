# Network Discovery

## MODIFIED Requirements

### Requirement: Proxmox inventory enrichment requires verified TLS
Proxmox inventory enrichment SHALL continue to require `proxmox_api_token` auth
with `tls_policy` `verify`. The requirement SHALL be satisfiable against a node
presenting a self-signed or privately-issued certificate by attaching CA trust
material to the credential rule.

#### Scenario: Verified enrichment with a pinned private CA
- **GIVEN** a Proxmox credential rule with `tls_policy` `verify` and a valid CA bundle for the node
- **WHEN** inventory enrichment resolves the source scope
- **THEN** resolution SHALL succeed
- **AND** a `proxmox` broker grant SHALL be minted

#### Scenario: skip_verify remains rejected for enrichment
- **GIVEN** a Proxmox credential rule with `tls_policy` `skip_verify`
- **WHEN** inventory enrichment resolves the source scope
- **THEN** resolution SHALL fail with `proxmox_tls_verification_required`

#### Scenario: The rejection reason reaches the operator
- **GIVEN** an enrichment rejected for a transport policy reason
- **WHEN** the plugin result is ingested
- **THEN** the surfaced message SHALL name the transport policy cause rather than only the ingestor module
