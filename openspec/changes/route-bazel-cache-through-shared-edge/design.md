## Context
The cache proxy has two materially different clients. BuildBuddy executors are Kubernetes pods and
use the proxy's private Service. Bazel clients on developer workstations, Forgejo runners, and
BuildBuddy workflow runners use the public TLS route. All authenticate through BuildBuddy, but they
do not share an execution platform: CI uses Linux remote executors while database-facing TestRunner
actions must execute on a fixture-reachable runner or native workstation.

The shared Envoy edge is managed in the adjacent GitOps repository. This repository owns the Bazel
profiles, developer/CI entry points, BuildBuddy deployment runbook, and configuration-drift tests.
The public route is already deployed; this change separates cache transport from execution ownership
and repairs the local integration lifecycle around that boundary.

## Goals / Non-Goals
- Goals:
  - Keep authenticated remote-cache traffic on the public TLS cache-proxy endpoint.
  - Reuse cache and BES transport without selecting a remote executor or foreign platform.
  - Make the guarded Bazel fixture lifecycle usable on a native developer host.
  - Give focused runs a matching single-shard provision target and an explicit cleanup contract.
  - Preserve BuildBuddy's native authentication as the authoritative access decision.
- Non-Goals:
  - Route remote execution, BES, or the BuildBuddy UI through the cache proxy.
  - Put a public IP or NodePort directly on the cache-proxy Service.
  - Store a BuildBuddy API key, JWT, TLS private key, or database credential in this repository.
  - Make integration tests part of the ordinary `make test` sweep.
  - Change the Forgejo integration suite's Linux RBE compilation model.

## Decisions

### Decision: Public TLS terminates at the shared Envoy gateway
The client endpoint is `grpcs://cache-proxy.carverauto.dev:443`. Envoy presents the public
certificate and forwards HTTP/2 gRPC over the cluster network to the existing Service on port 1985.
The backend Service remains `ClusterIP`, with no public load balancer or NodePort.

Consequences:
- Public traffic is encrypted and uses a stable DNS name.
- The chart does not need to own a second public address or certificate lifecycle.
- Plaintext port 1985 remains confined to the cluster network.

### Decision: Native BuildBuddy authentication remains authoritative
Envoy performs transport termination and routing only. Clients continue sending their existing
BuildBuddy credential; the cache proxy delegates remote authentication and JWT validation to the
upstream BuildBuddy instance without reparsing the JWT. The proxy's separate outbound key remains in
its Kubernetes Secret.

Consequences:
- Public exposure does not create a second credential system or a policy that can drift from
  BuildBuddy.
- Connectivity or an anonymous Capabilities response is not sufficient validation. A canary must
  perform a protected ActionCache/CAS operation with valid credentials and confirm invalid
  credentials are rejected.

### Decision: The proxy is the default cache hop for remote profiles
`build:remote_base`, and therefore `build:ci`, inherit the public cache-proxy endpoint. Remote
execution, BES, results URLs, and the bytestream URI prefix continue to name upstream BuildBuddy.
The ignored `.bazelrc.remote` contains credentials and local overrides only; it does not select a
cache profile.

Consequences:
- CI and remote builds use one cache path without per-entrypoint opt-in drift.
- A route rollback changes the cache endpoint back to upstream BuildBuddy; it does not alter executor
  routing or the in-cluster executor cache path.
- Legacy Make aliases may remain discoverable, but they do not reference a removed
  `build:cache_proxy` profile.

### Decision: Cache transport is independent from execution ownership
`build:cache_only` contains the public remote-cache endpoint, upstream bytestream prefix, upstream
BES endpoints, and cache transfer/compression settings. It MUST NOT set `--remote_executor`, a host
or target platform, `EXECUTOR=remote`, a remote JDK/toolchain, or Linux-only OpenSSL variables.
`build:remote_base` inherits `build:cache_only` and adds Linux RBE execution settings.

Consequences:
- A Darwin client can combine `build:cache_only` with `build:darwin_local`; a local Linux client can
  use `build:cache_only` with its native platform defaults.
- Compile and dependency outputs can be read from or written to the authenticated cache while the
  database-facing test action remains on the host that can reach the fixture.
- The same cache/BES endpoint declarations cannot silently diverge between local and RBE profiles.

### Decision: The caller owns the ordered Bazel lifecycle
The legacy `scripts/test-integration.sh` wrapper is removed. Developers, Forgejo, and the
BuildBuddy workflow invoke the same Bazel targets in the same order:

`sweep -> prepare -> [migrate] -> provision -> suite -> teardown`

Every guarded target receives `--//build:enable_integration_tests`. Test invocations explicitly
clear manual filters where a named manual target is selected, force only `TestRunner` local, and
disable test-result caching; the prepare binary explicitly clears the manual build filter. Fixture
and NATS credentials are forwarded only by explicit `test:database_env` / `test:nats_env` profiles
selected on those local, non-uploaded invocations. They are not global `test --test_env` values and
therefore never enter generic remote unit-test action metadata. The
caller reads `prepare_template`'s `needs_migration` output instead of starting the BEAM
unconditionally. A cache-only workstation does not disable all local-result uploads: locally
compiled action misses must remain able to populate the authenticated cache. Forgejo and
BuildBuddy may suppress local uploads because their compilation actions execute remotely.

The caller keeps fixture base URLs in `SRQL_TEST_DATABASE_URL` and `SRQL_TEST_ADMIN_URL`. It MUST
NOT export the base URL as `SERVICERADAR_TEST_DATABASE_URL`, because that variable is the final
per-shard override and suppresses `integration_env.exs` database-name derivation. One unique
numeric `GITHUB_RUN_ID` and attempt are set for the sequence, so every target derives the same
`sr_core_test_<run>_<attempt>[_sN]` names.

The dedicated Forgejo database workflow is outcome-bearing rather than optional: it validates both
fixture DSNs and the fixture CA before setup and fails when any are absent. Lifecycle steps do not
use missing-secret conditions to turn an intended database test run into a green no-op.

The credential setup normalizes both Kubernetes-derived and pre-set DSNs to explicit
`sslmode=verify-full`, so neither Rust nor Elixir can downgrade a CA-bearing connection to
plaintext or `verify_none`. For NodePort runs, the caller supplies the service DNS name separately through
`PGSSLSERVERNAME` and `SRQL_TEST_DATABASE_SERVER_NAME`, preserving certificate verification in
both the Rust and Elixir clients. The shared DSN remains `sslmode=verify-full`. Because
`tokio-postgres` accepts only `disable`, `prefer`, or `require`, the Rust lifecycle maps
`verify-ca`/`verify-full` to `require` only while building its `tokio-postgres` config; its rustls
connector still verifies the fixture CA and uses `PGSSLSERVERNAME` for the certificate name. Ecto
continues consuming the unmodified DSN and applies its native `verify_peer` behavior. The named
SRQL harness applies the same parser-boundary mapping before each direct tokio-postgres connection.
`provision_db_s0` through `provision_db_s7` pair mechanically with the generated shard test targets;
the unsuffixed target remains the CI/all-shard path.

Consequences:
- Bazel has no finalizer across separate invocations, so a local caller must invoke teardown after
  provisioning even when the shard is red. Forgejo retains its `always()` teardown step;
  BuildBuddy keeps the sequence in one shell with an EXIT trap whose teardown failure fails an
  otherwise-green step.
- Every caller establishes a unique numeric run identity, so concurrent developer and workflow
  runs do not collide on `sr_core_test_local`.
- Credential-bearing environment files are per-run, mode 0600, and removed on exit.
- The stale sweep derives `base/<database_oid>/PG_VERSION` for each pg_default disposable clone and
  uses that immutable directory marker's mtime. It never uses the shared `pg_database` relation
  path as a per-database age proxy, rejects non-positive thresholds, and does not force-disconnect
  an active candidate.
- Focused runs preserve the production lifecycle and cleanup rather than bypassing it with ad hoc Mix
  commands.

## Risks / Trade-offs
- The endpoint is reachable over the public Internet. TLS protects transport and BuildBuddy's native
  authentication protects cache RPCs; configuration tests prevent plaintext or executor drift.
- Database test actions must execute locally, so only their compilation and declared inputs benefit
  from remote execution/cache. The network-bound test itself cannot run on an executor without a
  route to the fixture.
- A killed local or workflow process cannot guarantee teardown. The stale-database sweep remains
  the backstop; normal failures use the local/BuildBuddy EXIT trap or Forgejo `always()` step.
- A focused shard provisions only its matching database, reducing shared-fixture writes and cleanup
  surface. Teardown still discovers the whole run prefix and is safe after either focused or full
  provisioning.
- `build:cache_only` preserves the host target platform. It therefore cannot be used directly to
  publish Linux/amd64 OCI targets from Darwin; macOS publishing keeps the existing CI-platform
  image build plus native crane/jq launcher path.

## Migration Plan
1. Factor cache/BES settings into `build:cache_only` and have `build:remote_base` inherit it without
   changing CI executor/platform behavior.
2. Add hermetic tests proving the cache-only profile carries no execution ownership.
3. Remove the broken shell/Make wrapper, add focused provision targets, and document the explicit
   guarded sequence and TLS environment contract.
4. Exercise a focused shard against a unique fixture run and prove no matching database
   remains afterward.
5. Run the ordinary lint/unit gates; Forgejo and BuildBuddy remain the authoritative Linux
   all-shard workflow callers.

Rollback removes the focused provision targets and points `build:remote_base` directly at the same
cache/BES settings. The broken shell wrapper is not restored. If the public route itself is
unhealthy, change the cache endpoint back to upstream BuildBuddy; do not change the executor or BES
endpoints.

## Open Questions
- None. Default proxy routing, native BuildBuddy authentication, host-local database test actions,
  and the guarded scratch-database lifecycle are existing approved constraints.
