# Complete Config Manager Adoption

## Why

`add-unified-config-and-secret-managers` built the capability: a schema, committed instances, a
rule set with conformance vectors, and ConfigManager + SecretManager in Rust, Go and Elixir, all
guarded by drift and coverage tests. That change is archived.

What it did not do is finish moving the call sites onto it. The system is real and verified, and
most of the repository still does not use it. Three gaps, each measured rather than assumed:

- **Go cannot resolve a secret at all.** `config/manager_secret/go` ships `FileProvider` only.
  The platform supplies every credential as an environment variable -- `//helm/serviceradar` uses
  `valueFrom.secretKeyRef` for all 38 of them, and nothing anywhere mounts
  `/etc/serviceradar/secrets` -- so the one provider Go has matches no deployment that exists.
  Rust and Elixir gained `EnvProvider`; Go did not.
- **No deployment mounts an instance.** `grep -rn "environment.binpb" helm/ docker/` returns
  nothing, so `saas`, `demo` and `onprem` have no instance to load. Only `localhost` and `ci`,
  which carry theirs inside the artifact, are exercised today.
- **Adoption is partial and therefore fragile.** `//rust/integration-db`, the srql harness and
  `//elixir/serviceradar_core:migrate_template` resolve through the managers. The Elixir
  integration shards still read `SRQL_TEST_*` through `buildbuddy_setup_fixture_env.sh`, which is
  the bridge the whole change exists to delete.

The half-migrated state costs more than either end state. Two mechanisms now describe the same
fixture, and they can disagree: during the CI work that prompted this split, the config-driven
path named an endpoint the environment-driven path never used, and the mismatch was only visible
as a DNS failure twenty minutes into a run.

This change finishes the migration and removes the old machinery, so there is exactly one way a
component learns where its database is.

## What Changes

- **Go SecretManager gains `EnvProvider` + `EnvironmentProvider`**, with the same logical-name
  transform and the same "empty variable is absent, not an empty credential" rule as Rust and
  Elixir, covered by the same test cases. Everything else in the Go phase depends on it.
- **The remaining Elixir call sites move onto the managers** -- `config/test.exs` and its fourteen
  alias pairs, `integration_env.exs`, `database_bootstrap_integration_test.exs`, both
  `test_helper.exs` presence probes, and the application configuration in `serviceradar_core`,
  `serviceradar_core_elx`, `web-ng` and `serviceradar_agent_gateway`.
- **The Go call sites move**, including deleting `EnvConfigLoader` -- which derives names from
  struct tags by reflection and accepts a whole config document through `SERVICERADAR_CONFIG_JSON`,
  so no scan can enumerate it -- and renaming `NATS_CREDSFILE`, a spelling nothing sets.
- **The bootstrap layers are re-founded on the managers** in all three languages, per Decision 11.
- **The old machinery is retired**: `buildbuddy_setup_fixture_env.sh` and its workflow step,
  `scripts/ci/configure-srql-fixture.sh`, and the `.bazelrc` `database_env` / `nats_env` profiles.
- **Deployment carries the environment**: `SERVICERADAR_ENV` in Compose, Helm and Kubernetes, and
  a mounted instance for the deployed kinds.
- An **automated gate** fails the build if a direct read of a schema-covered name reappears.

## Impact

- Affected specs: `unified-configuration` (three added requirements covering adoption, secret
  resolution in every language, and the deployed instance source)
- Affected code: `config/manager_secret/go`, `elixir/serviceradar_core`, `elixir/web-ng`,
  `elixir/serviceradar_agent_gateway`, `elixir/serviceradar_core_elx`, `go/pkg/config`,
  `go/pkg/k8sinventory`, `go/pkg/trivysidecar`, `rust/config-bootstrap`, `helm/serviceradar`,
  `docker/compose`, `buildbuddy.yaml`, `.bazelrc`
- Risk is concentrated in 7c and 9: those touch how shipped services boot, unlike the test-only
  call sites already migrated. Sequence them last and behind the demo namespace.
