## ADDED Requirements
### Requirement: Bazel clients can opt in to the authenticated public cache proxy
The repository SHALL provide an opt-in Bazel profile that sends remote-cache traffic to
`grpcs://cache-proxy.carverauto.dev:443` and preserves
`remote_bytestream_uri_prefix=carverauto.buildbuddy.io`.

#### Scenario: Explicit cache-proxy build uses public TLS
- **GIVEN** the shared public cache-proxy route is healthy
- **AND** the Bazel client has a valid BuildBuddy credential outside source control
- **WHEN** the client builds with `--config=cache_proxy`
- **THEN** remote-cache RPCs SHALL use `grpcs://cache-proxy.carverauto.dev:443`
- **AND** build-event artifact URIs SHALL continue naming `carverauto.buildbuddy.io`

#### Scenario: Protected cache RPC rejects an invalid credential
- **GIVEN** the public TLS listener is reachable
- **WHEN** a client attempts a protected ActionCache or CAS operation without a valid BuildBuddy
  credential
- **THEN** the cache proxy SHALL reject that operation through its native BuildBuddy
  authentication path
- **AND** an anonymous Capabilities response SHALL NOT be treated as proof of authorization

### Requirement: Cache-proxy selection does not change default BuildBuddy services
The cache-proxy profile SHALL change only the Bazel remote-cache endpoint and bytestream URI
prefix. Remote execution, BES, results URLs, `build:ci`, `build:remote`, and normal Make targets
MUST retain their existing direct BuildBuddy behavior.

#### Scenario: Canonical unit tests run without the proxy by default
- **WHEN** a developer runs `make test`
- **THEN** the canonical optimized CI unit-test sweep SHALL run without selecting
  `build:cache_proxy`
- **AND** integration and acceptance tests SHALL remain excluded by the canonical filters

#### Scenario: Remote execution and BES bypass the cache proxy
- **WHEN** a client explicitly selects `build:cache_proxy`
- **THEN** only remote-cache RPCs SHALL target the cache-proxy hostname
- **AND** remote execution, BES, and results links SHALL continue targeting
  `carverauto.buildbuddy.io`

#### Scenario: A generated remote rc opts a CI job into the proxy
- **WHEN** a CI job writes `build:ci --config=cache_proxy` to the ignored `.bazelrc.remote`
- **THEN** that file SHALL be imported after the checked-in remote, CI, and cache profiles
- **AND** the cache-proxy endpoint SHALL win without moving credentials into source control

### Requirement: Cached Make targets reuse canonical workspace recipes and scope
The Makefile SHALL expose discoverable cached workspace build and unit-test targets that reuse
their corresponding canonical recipe bodies and full-workspace scope. The build canary SHALL use
the approved optimized CI flags plus the cache-proxy profile, while the test canary SHALL add the
cache-proxy profile to the canonical unit-test flags and filters.

#### Scenario: Cached unit-test sweep stays aligned with the canonical test target
- **WHEN** a developer runs `make test-cache`
- **THEN** Make SHALL execute the same workspace scope and test-tag filters as `make test`
- **AND** it SHALL additionally select `--config=cache_proxy`

#### Scenario: Cached workspace build stays aligned with the workspace build target
- **WHEN** a developer runs `make build-workspace-cache`
- **THEN** Make SHALL execute the `build-workspace` recipe for `//...`
- **AND** it SHALL use the optimized CI profile plus `--config=cache_proxy`

### Requirement: Public ingress preserves a private backend and source-controlled secret hygiene
The public cache-proxy route SHALL terminate TLS at the shared gateway while the cache-proxy
Service remains `ClusterIP`, and no BuildBuddy client credential, proxy upstream key, or TLS
private key SHALL be committed to this repository.

#### Scenario: Gateway removal does not interrupt executor cache traffic
- **GIVEN** executors use the cache-proxy Service FQDN directly
- **WHEN** the public gateway route is disabled or removed after clients stop opting in
- **THEN** executors SHALL continue using the internal cache-proxy path
- **AND** default Bazel clients SHALL continue using the direct upstream BuildBuddy path

#### Scenario: Repository configuration contains no authentication secret
- **WHEN** the public endpoint and opt-in profiles are reviewed
- **THEN** the repository SHALL contain endpoint and routing configuration only
- **AND** BuildBuddy credentials and TLS private keys SHALL remain in their designated ignored
  files, runner configuration, or Kubernetes Secrets
