## MODIFIED Requirements
### Requirement: Docker Compose stack boots without manual intervention
The Docker Compose stack SHALL reach a healthy state after a clean `docker compose up -d` without manual migrations or ad-hoc fixes, while generating unique per-install trust-boundary secrets instead of relying on shared static defaults.

#### Scenario: Clean boot
- **WHEN** a user removes compose volumes and runs `docker compose up -d`
- **THEN** all required services become healthy within the expected startup window
- **AND** no manual schema or credential steps are required

#### Scenario: First boot generates unique runtime trust secrets
- **GIVEN** a clean Docker Compose environment with no secret volumes
- **WHEN** the stack performs bootstrap
- **THEN** it generates unique runtime secret material for Erlang distribution, Phoenix signing, and plugin download signing
- **AND** those values are persisted for reuse on restart
- **AND** the stack does not depend on shipped static defaults for those trust boundaries

### Requirement: NATS JWT credentials are consistently used
All services that connect to NATS in Docker Compose SHALL use JWT credentials and succeed authentication, and the stack SHALL NOT publish unauthenticated NATS monitoring externally by default.

#### Scenario: NATS authentication
- **WHEN** services establish NATS connections
- **THEN** NATS logs show successful JWT authentication
- **AND** no services attempt anonymous or non-JWT connections

#### Scenario: Monitoring stays internal by default
- **WHEN** the main Docker Compose stack is rendered with default settings
- **THEN** the NATS monitoring endpoint is not published to non-loopback host interfaces by default
- **AND** any external monitoring exposure requires explicit operator opt-in

## ADDED Requirements
### Requirement: Docker Compose SPIRE bootstrap artifacts are integrity pinned
The Docker Compose SPIRE bootstrap path MUST NOT download and execute unsigned binaries from the network at runtime.

#### Scenario: SPIRE bootstrap uses vetted artifacts
- **WHEN** the compose SPIRE bootstrap initializes the SPIRE server CLI or agent binary
- **THEN** it uses binaries that are already present in the image or a vetted local artifact path
- **OR** it verifies a pinned checksum or signature before extracting and executing a downloaded artifact

#### Scenario: Unverified runtime download is rejected
- **WHEN** the compose SPIRE bootstrap cannot establish the configured integrity material for a downloaded artifact
- **THEN** bootstrap fails closed
- **AND** it does not execute the downloaded binary
