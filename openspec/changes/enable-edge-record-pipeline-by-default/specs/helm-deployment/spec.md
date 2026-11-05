# helm-deployment Delta

## ADDED Requirements

### Requirement: The chart carries no edge-record pipeline values
The Helm chart SHALL NOT define, read, or render any value that enables, disables,
or configures the durable edge-record pipeline. That covers the contract registry,
the issuer key, producer opt-ins, and the spool budget. The chart SHALL fail to
render, with a message that names the removed `edgeRecords` block and says to
delete it, when any `edgeRecords` key is set. The gateway's NATS publish
permissions for the edge-record subjects SHALL be unconditional. For the cutover
release only, the secret generator SHALL keep generating `edge-issuer-seed`, and
wherever that generator manages the Secret (`secrets.autoGenerate` is not false)
core SHALL keep its mount and `SERVICERADAR_EDGE_ISSUER_KEY_FILE`, no longer gated
on any pipeline value, as the one-time import input for the issuer key. Where the
operator owns the Secret, the chart SHALL NOT point core at a seed file it cannot
guarantee exists. The release after cutover removes the mount, the variable and
the generated key.

#### Scenario: An install from default values
- **WHEN** the chart renders with its default values
- **THEN** no edge-record enable variable or registry variable is rendered for
  core or the gateway
- **AND** in the cutover release core renders the issuer key mount and
  `SERVICERADAR_EDGE_ISSUER_KEY_FILE`
- **AND** the gateway may publish to the edge-record subjects

#### Scenario: The operator owns the secrets Secret
- **GIVEN** values that set `secrets.autoGenerate: false`
- **WHEN** the chart renders in the cutover release
- **THEN** core renders neither the issuer key mount nor
  `SERVICERADAR_EDGE_ISSUER_KEY_FILE`, and generates its own issuer key

#### Scenario: Values from before the switch are still set
- **GIVEN** values that set `edgeRecords.enabled` and `edgeRecords.contractRegistry`
- **WHEN** the chart renders
- **THEN** the render fails
- **AND** the message says the `edgeRecords` block was removed and must be deleted
