## ADDED Requirements

### Requirement: Add-on Manifest Contract
The system SHALL define a declarative add-on manifest (`addon.yaml`) that fully
describes an optional native agent capability. The manifest SHALL include a stable
identifier, semantic version, `kind: native`, a delivery model, a supervision model,
the capability strings the add-on advertises, requirements (base-agent version
floor, platform allow-list, required OS capabilities, privilege/run-as envelope),
per-architecture artifact references where applicable, execution metadata (binary,
install path, unit names), state directories, and a reference to a
`config.schema.json` JSON Schema used to render its configuration form. An add-on
author SHALL be able to make a capability selectable in Edge Ops by adding an
`addon.yaml`, a `config.schema.json`, and one inventory entry, without bespoke
control-plane or UI integration.

#### Scenario: Valid manifest is accepted
- **GIVEN** an add-on with a well-formed `addon.yaml` and `config.schema.json`
- **WHEN** the manifest is validated
- **THEN** validation SHALL succeed
- **AND** the add-on SHALL become eligible for catalog ingestion

#### Scenario: Manifest missing required fields is rejected
- **GIVEN** an add-on manifest missing a required field (id, version, kind, delivery, or supervision)
- **WHEN** the manifest is validated
- **THEN** validation SHALL fail with a bounded diagnostic naming the missing field
- **AND** the add-on SHALL NOT be ingested into the catalog

#### Scenario: Delivery-agnostic catalog metadata
- **GIVEN** an add-on whose delivery model changes (for example from `os-package` to `pushed-artifact`)
- **WHEN** the add-on is re-published with an updated manifest
- **THEN** its catalog identity and operator-facing selection SHALL be unchanged
- **AND** only the delivery/supervision metadata behind the manifest SHALL differ

### Requirement: Base And Add-on Packaging Boundary
The base `serviceradar-agent` package SHALL contain only the core agent and SHALL
NOT bundle, install, enable, or start any optional capability. Every optional
capability SHALL be delivered as a separately built, signed add-on that remains
dormant until selected for an agent.

#### Scenario: Base agent install activates no optional capability
- **GIVEN** an operator installs the base `serviceradar-agent` package
- **WHEN** installation completes
- **THEN** no optional add-on binary, unit, timer, or state directory SHALL be installed or enabled
- **AND** the agent SHALL run with only core capabilities until an add-on is selected

#### Scenario: Add-on is dormant until selected
- **GIVEN** an add-on artifact is present on an agent host (via package or pushed artifact)
- **WHEN** no feature-set assignment enables it for that agent
- **THEN** the add-on SHALL NOT run
- **AND** the agent SHALL NOT advertise the add-on as active

### Requirement: Add-on Delivery Models
The framework SHALL support three delivery models — `compiled-in` (a capability
already present in the base agent, toggled by configuration), `pushed-artifact` (a
signed per-architecture tarball delivered over the existing runtime-push rail), and
`os-package` (a deb/rpm installed out of band) — and SHALL select the per-agent
artifact by the agent's architecture.

#### Scenario: Pushed-artifact delivery verifies before activation
- **GIVEN** an add-on with `delivery: pushed-artifact` is enabled for an agent
- **WHEN** the agent fetches the signed artifact for its architecture
- **THEN** the agent SHALL verify the artifact content hash and signature before staging
- **AND** the agent SHALL activate the staged artifact only after verification succeeds
- **AND** the agent SHALL fall back to the last-known-good state on verification or activation failure

#### Scenario: Compiled-in delivery is a configuration toggle
- **GIVEN** an add-on with `delivery: compiled-in`
- **WHEN** a feature-set assignment enables it for an agent
- **THEN** no binary delivery SHALL occur
- **AND** the agent SHALL enable the already-present capability by configuration

#### Scenario: Architecture mismatch is reported, not run
- **GIVEN** an add-on that does not publish an artifact for an agent's architecture
- **WHEN** the add-on is selected for that agent
- **THEN** the system SHALL report the add-on as unavailable for that agent with a bounded reason
- **AND** SHALL NOT deliver an artifact for a different architecture

### Requirement: Add-on Supervision Models
The framework SHALL support supervision models `config-toggle`, `agent-sidecar`,
`systemd-service`, `systemd-timer` (a scheduled oneshot whose output the agent
ingests), and `ephemeral-helper` (spawned per session/job). The `agent-sidecar`
model SHALL run each add-on as an isolated subprocess that communicates with the
agent over gRPC on a restricted local transport with mutual TLS, using the
subprocess-plus-gRPC plugin mechanism (HashiCorp go-plugin); the agent SHALL manage
the plugin lifecycle with health checks, restart backoff, and a circuit breaker.
Add-on plugins MAY be implemented in any language that serves the gRPC contract
(for example Go or Rust). The framework SHALL NOT load add-ons in-process via the Go
standard library `plugin` mechanism. Enabling or disabling one add-on SHALL NOT
disrupt other add-ons.

#### Scenario: Disabling one add-on does not affect others
- **GIVEN** an agent running two enabled add-ons
- **WHEN** an operator disables one of them
- **THEN** that add-on SHALL be stopped gracefully
- **AND** the other add-on SHALL continue running uninterrupted

#### Scenario: Supervised sidecar restarts within bounds
- **GIVEN** an `agent-sidecar` add-on whose subprocess exits unexpectedly
- **WHEN** the supervisor detects the exit
- **THEN** it SHALL restart the subprocess with bounded backoff
- **AND** SHALL stop restarting and report a degraded state if a restart rate threshold is exceeded

#### Scenario: Add-on subprocess crash does not crash the agent
- **GIVEN** an `agent-sidecar` add-on that panics or crashes
- **WHEN** the subprocess terminates abnormally
- **THEN** the agent process SHALL remain running
- **AND** SHALL report the add-on as unhealthy and attempt bounded restart

#### Scenario: Polyglot plugin over the gRPC contract
- **GIVEN** an `agent-sidecar` add-on implemented in a non-Go language that serves the add-on gRPC contract and handshake
- **WHEN** the agent launches and connects to it
- **THEN** the agent SHALL supervise and communicate with it identically to a Go add-on

### Requirement: Add-on Dependency Isolation
Adding or enabling an add-on SHALL NOT grow the base `serviceradar-agent` binary's
dependency set or size. The base agent SHALL interact with `agent-sidecar` add-ons
only through the plugin gRPC interface and SHALL NOT import an add-on's
implementation package. The build SHALL enforce this isolation.

#### Scenario: Base agent does not import add-on implementation packages
- **GIVEN** a new add-on added to the repository
- **WHEN** the base agent's transitive package set is computed for a build
- **THEN** it SHALL NOT include the add-on's implementation packages or their dependencies
- **AND** the base agent's binary size SHALL NOT increase as a result of adding the add-on

#### Scenario: Build rejects an add-on dependency leaking into the base agent
- **GIVEN** a change that causes the base agent to import an add-on implementation package
- **WHEN** the dependency-isolation check runs in CI
- **THEN** the check SHALL fail
- **AND** SHALL identify the offending import path

### Requirement: Add-on Catalog And Approval
The control plane SHALL maintain a catalog of available add-ons as reviewable
packages with a staged → approved → revoked lifecycle and recorded provenance
(source reference, content digests, signature verification result). Only an approved
add-on SHALL be assignable to an agent.

#### Scenario: Imported add-on starts staged
- **GIVEN** a signed add-on is imported from the discovery index
- **WHEN** import and verification succeed
- **THEN** the add-on SHALL be recorded as staged with its provenance and verification result
- **AND** the add-on SHALL NOT be assignable until approved

#### Scenario: Non-approved add-on cannot be assigned
- **GIVEN** a staged or revoked add-on
- **WHEN** an operator attempts to assign it to an agent
- **THEN** the assignment SHALL be rejected
- **AND** the operator SHALL be shown the add-on's current lifecycle state

### Requirement: Feature-set Selection And Targeting
Operators SHALL select feature sets — a single add-on or a named bundle of add-ons —
and target which agents receive them, either an individual agent or a cohort of
agents. A selection SHALL persist an assignment that drives downward delivery and
configuration. Selection SHALL be infrastructure-level (per-agent or per-cohort) and
SHALL NOT introduce row-level tenant scoping.

#### Scenario: Operator targets specific agents
- **GIVEN** an approved add-on and a chosen set of target agents
- **WHEN** the operator assigns the add-on to those agents
- **THEN** the system SHALL persist an assignment for each targeted agent
- **AND** the assignment SHALL be compiled into those agents' effective configuration

#### Scenario: Cohort targeting applies to matching agents
- **GIVEN** an approved add-on assigned to a cohort
- **WHEN** the assignment is saved
- **THEN** the system SHALL apply it to the agents in the cohort
- **AND** SHALL present which targeted agents can and cannot run the add-on before applying

### Requirement: Capability Gating And Reconciliation
The control plane SHALL only deliver an add-on's configuration to an agent when the
feature set is enabled for that agent and the agent can run or be delivered the
capability. Agents SHALL report per-add-on state (installed, available, active, or
unhealthy with a degradation reason), and the system SHALL reconcile operator-desired
assignments against agent-observed state and surface drift.

#### Scenario: Base-package agent does not receive unrunnable sections
- **GIVEN** an add-on selected for an agent whose build/platform cannot run it
- **WHEN** the control plane compiles that agent's configuration
- **THEN** it SHALL omit the add-on's configuration section
- **AND** SHALL surface the selection as drift (selected but unsupported)

#### Scenario: Unhealthy add-on is surfaced
- **GIVEN** an enabled add-on that fails to acquire a required OS capability
- **WHEN** the agent reports its add-on state
- **THEN** it SHALL report the add-on as unavailable or unhealthy with a bounded reason
- **AND** the UI SHALL show the add-on as degraded rather than active

### Requirement: Add-on Privilege And Security Envelope
The framework SHALL derive each add-on's privilege envelope from its manifest
(`run_as` and required OS capabilities) and SHALL apply file capabilities and process
hardening accordingly. File capabilities for pushed artifacts SHALL be applied by a
root-owned helper at activation, not by the non-root agent. The operator UI SHALL
surface when an add-on requires elevated privileges.

#### Scenario: Required capabilities applied by privileged helper
- **GIVEN** a pushed-artifact add-on declaring required OS capabilities
- **WHEN** the artifact is activated on a host
- **THEN** a root-owned helper SHALL apply the declared file capabilities to the add-on binary
- **AND** the non-root agent SHALL NOT require elevated privileges to enable the add-on

#### Scenario: Elevated privilege is disclosed before selection
- **GIVEN** an add-on whose manifest requests root or elevated OS capabilities
- **WHEN** an operator views the add-on in the catalog
- **THEN** the UI SHALL disclose that the add-on requires elevated privileges
