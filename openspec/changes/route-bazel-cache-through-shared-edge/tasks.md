## 1. Bazel and Make configuration
- [x] 1.1 Route `build:remote_base` cache traffic through the public `grpcs` endpoint while
      preserving the upstream bytestream, executor, and BES endpoints.
- [x] 1.2 Keep canonical workspace build/test recipes shared and remove live references to the
      retired `build:cache_proxy` profile.

## 2. Operational contract
- [x] 2.1 Document the public TLS/private Service boundary, native authentication, and secret
      custody.
- [x] 2.2 Remove the obsolete ClusterIP workflow probe and make remote profiles inherit the proxy
      cache route without generated-rc profile selection.
- [x] 2.3 Document cache-endpoint rollback while preserving direct executor/BES and the in-cluster
      executor cache path.

## 3. Drift prevention and verification
- [x] 3.1 Add a Bazel static test covering the TLS endpoint, bytestream prefix, remote-service
      isolation, remote-rc precedence, inherited Make recipes, and private backend Service.
- [x] 3.2 Run the focused Bazel test and dry-run the canonical Make targets.
- [x] 3.3 Run `openspec validate route-bazel-cache-through-shared-edge --strict`.
- [x] 3.4 Run `git diff --check` and review the scoped diff.

## 4. Host-native Bazel integration lifecycle
- [x] 4.1 Factor `build:cache_only` from `build:remote_base` without inheriting an executor,
      platform, remote toolchain, or Linux-only environment.
- [x] 4.2 Remove the policy-violating shell/Make wrapper and document the lifecycle as an explicit
      sequence of guarded Bazel targets.
- [x] 4.3 Add `provision_db_s0` through `provision_db_s7` from the canonical shard list while
      retaining the unsuffixed all-shard CI target.
- [x] 4.4 Document canonical `SRQL_TEST_*` base URLs, one caller-owned numeric run identity, and
      explicit teardown after a red shard.
- [x] 4.5 Forward both Rust and Elixir TLS server-name variables for verified NodePort access,
      and normalize libpq `verify-ca`/`verify-full` modes only at the `tokio-postgres` parser
      boundary.
- [x] 4.6 Add hermetic cache-profile regressions, including host-native execution isolation and
      valid build-profile references.
- [x] 4.7 Reconcile the fixture skill, developer/BuildBuddy documentation, and integration workflow
      path coverage.
- [x] 4.8 Guard the named SRQL fixture suites with the same explicit shared-fixture opt-in and
      local, non-cached TestRunner policy as the core lifecycle.
- [x] 4.9 Scope database and NATS credential forwarding to explicit integration profiles, run the
      named SRQL suites in both workflow systems, and keep generic remote tests credential-free.
- [x] 4.10 Enforce verified TLS across Forgejo, BuildBuddy, core, and SRQL parser boundaries; make
      cleanup outcome-bearing and repair the per-database stale-age query.

## 5. Verification
- [x] 5.1 Run `openspec validate route-bazel-cache-through-shared-edge --strict`.
- [x] 5.2 Query all eight focused provision targets and run the cache configuration plus pure Rust
      lifecycle tests.
- [x] 5.3 Run a focused integration shard against the TLS fixture and prove teardown removed the run
      prefix.
- [x] 5.4 Run `make lint`, `make test`, and `git diff --check`.
