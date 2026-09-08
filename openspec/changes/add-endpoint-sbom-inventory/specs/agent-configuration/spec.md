## ADDED Requirements

### Requirement: Endpoint Inventory Configuration
The `serviceradar-agent` SHALL support endpoint inventory configuration through the same effective configuration resolution path used for managed agent collectors.

#### Scenario: Remote profile enables endpoint inventory
- **GIVEN** an agent has no local endpoint inventory override
- **AND** the control plane assigns a profile with endpoint inventory enabled
- **WHEN** the agent resolves its effective configuration
- **THEN** the agent SHALL schedule endpoint inventory collection according to the profile cadence
- **AND** it SHALL apply the profile source, redaction, and size-limit settings

#### Scenario: Local endpoint inventory override
- **GIVEN** an agent has a local endpoint inventory configuration file
- **WHEN** the agent resolves endpoint inventory configuration
- **THEN** the local configuration SHALL take precedence over the remote profile
- **AND** the agent SHALL log that a local endpoint inventory override is active

#### Scenario: Invalid endpoint inventory configuration
- **GIVEN** an endpoint inventory configuration contains an invalid cadence, unsupported source, or unsafe limit
- **WHEN** the agent validates configuration
- **THEN** the endpoint inventory collector SHALL remain disabled
- **AND** the agent SHALL report a bounded configuration error in status

### Requirement: Endpoint Inventory Spool Validation
The agent SHALL validate local endpoint inventory spool artifacts before upload.

#### Scenario: Valid spool artifact uploaded
- **GIVEN** the endpoint inventory collector writes a valid bounded CycloneDX JSON artifact to the configured spool location
- **WHEN** the agent reads the spool artifact
- **THEN** the agent SHALL validate format, size, scan metadata, and digest
- **AND** it SHALL upload the artifact and normalized summary through the configured control-plane path only when the package-set or artifact hash changed, the reconcile-floor interval is reached, or an authorized force-fresh-scan command is received

#### Scenario: Invalid spool artifact rejected
- **GIVEN** the endpoint inventory collector writes malformed JSON or a mismatched digest
- **WHEN** the agent reads the spool artifact
- **THEN** the agent SHALL reject the artifact
- **AND** it SHALL keep the previous successful endpoint inventory state

### Requirement: Endpoint Inventory Local Cache
The agent SHALL persist a local last-known-good endpoint inventory cache that can serve unchanged scan decisions and on-demand query commands.

#### Scenario: Cache updated after successful scan
- **GIVEN** endpoint inventory collection succeeds
- **WHEN** the agent validates the collector output
- **THEN** it SHALL persist normalized package identities, package-set hash, artifact hash, source summaries, scan timestamp, collector version, and redaction policy in the local cache
- **AND** it SHALL record whether the package-set hash has been uploaded successfully

#### Scenario: Control plane unavailable during changed scan
- **GIVEN** endpoint inventory collection succeeds with a changed package-set hash
- **AND** the control plane upload path is unavailable
- **WHEN** the agent handles the scan result
- **THEN** it SHALL keep the changed inventory in the local cache
- **AND** it SHALL retry upload according to bounded retry policy without losing the previous uploaded hash metadata

#### Scenario: Cache answers on-demand query
- **GIVEN** an agent has a valid local endpoint inventory cache
- **WHEN** it receives an endpoint inventory query command over the control stream
- **THEN** it SHALL evaluate supported predicates against the local cache
- **AND** it SHALL return compact results without requiring a package manager rescan unless the command requests and is authorized for a fresh scan

### Requirement: Endpoint Inventory On-Demand Command Policy
The agent SHALL enforce endpoint inventory policy and command bounds before running live inventory commands.

#### Scenario: Unsupported predicate rejected
- **GIVEN** an endpoint inventory query command contains an unsupported predicate or unsafe limit
- **WHEN** the agent validates the command
- **THEN** it SHALL reject the command with a bounded error
- **AND** it SHALL NOT run a fresh scan or upload an artifact

#### Scenario: Disabled source cannot be queried freshly
- **GIVEN** endpoint inventory policy enables OS packages only
- **WHEN** an on-demand command requests a fresh language-manifest scan
- **THEN** the agent SHALL reject the fresh source request
- **AND** it SHALL NOT collect the disabled source

### Requirement: Endpoint Inventory Uploads Are Jittered
The agent SHALL spread correlated endpoint inventory uploads over a window to avoid synchronized fleet upload bursts.

#### Scenario: Correlated changes spread over a window
- **GIVEN** many agents detect a changed package set at nearly the same time, such as a fleet-wide patch
- **WHEN** they schedule changed-inventory uploads
- **THEN** each agent SHALL apply a configured upload jitter, distinct from the scan-timer randomized delay, before uploading
- **AND** uploads SHALL be distributed over the jitter window rather than sent simultaneously

### Requirement: Force-Fresh Endpoint Inventory Scans Are Guarded
The agent SHALL treat a force-fresh endpoint inventory scan as a guarded, optional, device-scoped capability that is disabled by default. The control plane authorizes the requesting actor before dispatch; the agent enforces local policy, disabled-source rejection, and a per-agent single-flight semaphore.

#### Scenario: Force-fresh requires authorization and policy
- **GIVEN** the control plane has authorized an on-demand command that requests a fresh scan
- **WHEN** the agent receives the command
- **THEN** it SHALL run the fresh scan only if endpoint inventory policy allows the requested sources
- **AND** it SHALL reject disabled sources even if the command was server-authorized

#### Scenario: Force-fresh is single-flight per agent
- **GIVEN** a force-fresh scan is already running on an agent
- **WHEN** another force-fresh command arrives for that agent
- **THEN** the agent SHALL NOT start a second concurrent scan
- **AND** it SHALL coalesce or reject the additional request

#### Scenario: Force-fresh disabled by default
- **GIVEN** endpoint inventory policy does not enable force-fresh
- **WHEN** a fresh-scan command is received
- **THEN** the agent SHALL answer from its local cache or report fresh-scan unavailable
- **AND** it SHALL NOT run a package-manager rescan

### Requirement: Agent Status Heartbeat Carries Standing-Question Result Counts
The agent status heartbeat SHALL be designed to carry operator-defined standing-question result counts as a forward-compatible field, so continuously-evaluated fleet predicates can feed continuous aggregates without a later protocol change.

#### Scenario: Heartbeat includes standing-question counts
- **GIVEN** an agent has evaluated standing inventory predicates against its local cache
- **WHEN** it sends its next status heartbeat
- **THEN** the heartbeat SHALL include standing-question result counts in a structured field
- **AND** the field SHALL be present in the protocol even if the server-side consumer is not yet implemented
