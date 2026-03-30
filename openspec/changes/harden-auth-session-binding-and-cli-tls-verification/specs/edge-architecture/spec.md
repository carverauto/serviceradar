## ADDED Requirements
### Requirement: Administrative bootstrap CLI HTTPS transport always verifies certificates
Control-plane bootstrap and administrative CLI commands that communicate with ServiceRadar over HTTPS SHALL always enforce TLS certificate verification and SHALL NOT expose a transport option that disables certificate verification.

#### Scenario: CLI bootstrap command verifies HTTPS certificates
- **GIVEN** an operator runs a bootstrap or administrative CLI command against an `https://` ServiceRadar endpoint
- **WHEN** the CLI opens the HTTPS connection
- **THEN** the client SHALL verify the server certificate chain and hostname
- **AND** the command SHALL NOT offer a `tls-skip-verify` style bypass

#### Scenario: Script passes removed TLS bypass flag
- **GIVEN** an operator or script still passes a removed TLS verification bypass flag to a hardened CLI command
- **WHEN** the CLI parses the arguments
- **THEN** the command SHALL reject the unknown or unsupported flag
- **AND** SHALL NOT proceed with an insecure HTTPS connection
