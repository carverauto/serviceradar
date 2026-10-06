## ADDED Requirements

### Requirement: Latest Edge Package Download
The CLI MUST download `serviceradar-nats` for `edge install leaf`, and the collector package for `edge install collector`, from the latest published ServiceRadar GitHub release when `--version` is omitted.
An explicit `--version` MUST select that release instead. `edge install agent` MUST still require `--version`.

#### Scenario: Leaf install uses the latest NATS package
- **WHEN** the operator runs `edge install leaf` without `--version`
- **THEN** the CLI selects the `serviceradar-nats` asset for the host format and architecture from the latest GitHub release and downloads that asset

#### Scenario: Pinned release
- **WHEN** the operator passes `--version` to `edge install leaf` or `edge install collector`
- **THEN** the CLI downloads the asset for that version and does not query the latest release

#### Scenario: Agent version stays required
- **WHEN** the operator runs `edge install agent` without `--version`
- **THEN** the command fails and says that `--version` is required

### Requirement: Collectors Follow a Working Local Leaf
The CLI MUST NOT apply an edge-site collector bundle until the local `serviceradar-nats` service is active.
An edge-site collector whose `nats_leaf_url` is blank MUST be configured with the leaf's local TLS client URL, derived from `local_listen`, and a wildcard bind MUST become `127.0.0.1`.
An explicit `nats_leaf_url` MUST remain the collector URL.

#### Scenario: Collector install waits for the leaf
- **WHEN** the operator runs `edge install collector` for a collector bound to an edge site and `serviceradar-nats` is not active
- **THEN** the command fails before applying the collector bundle and tells the operator to install the leaf first

#### Scenario: Blank leaf URL uses the local client address
- **WHEN** a collector package is assigned to an edge site whose `nats_leaf_url` is blank and whose leaf listens on `0.0.0.0:4222`
- **THEN** the generated collector configuration sets its NATS URL to `tls://127.0.0.1:4222`

#### Scenario: Operator leaf URL wins
- **WHEN** a collector package is assigned to an edge site with `nats_leaf_url` set
- **THEN** the generated collector configuration uses that URL

### Requirement: Edge Site JSON Exposes the Local Client URL
The existing edge-site API, which requires `settings.edge.manage`, MUST include the leaf server's `local_listen` and the derived `client_url` in its JSON.

#### Scenario: Show site
- **WHEN** an authorized caller reads an edge site whose leaf listens on `0.0.0.0:4222`
- **THEN** the leaf server object includes `local_listen` of `0.0.0.0:4222` and `client_url` of `tls://127.0.0.1:4222`
