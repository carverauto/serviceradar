# NetBox Inventory Plugin

## ADDED Requirements

### Requirement: NetBox credentials live in the credential store
The NetBox package SHALL declare a credential profile, and its API token SHALL be
supplied by a credential rule rather than written into plugin assignment
parameters.

#### Scenario: Token is supplied by a credential rule
- **GIVEN** a NetBox credential rule with `api_token` auth
- **WHEN** the inventory sync assignment is materialised
- **THEN** the assignment parameters SHALL carry a credential reference
- **AND** SHALL NOT carry the token value

#### Scenario: NetBox appears in the credential UI
- **GIVEN** an operator on the credential rules page
- **WHEN** they create a new credential
- **THEN** NetBox SHALL be offered as a provider

### Requirement: NetBox sources are configured from settings
A NetBox source SHALL be creatable from the Settings UI, and a missing
configuration SHALL be reported specifically.

#### Scenario: Missing credential is named
- **GIVEN** a NetBox source with a base URL and no bound credential rule
- **WHEN** the inventory sync runs
- **THEN** the result SHALL name the missing credential rather than reporting only that no sources are configured
