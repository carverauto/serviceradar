# KV Regression Safeguards

We’ve already burned time debugging missing KV wiring (mapper, flowgger, datasvc RBAC). This doc captures a pragmatic plan for catching similar regressions in CI before images reach GHCR.

## 1. Unit Tests Per Binary

- **Go services**: add a `TestKVBootstrap` alongside each `cmd/<service>` package. Use `config.ServiceDescriptorFor(...)`, set `CONFIG_SOURCE=kv`, inject a fake KV client via `withKVClientFactory`, and assert that `config.ServiceWithTemplateRegistration(...)` returns a non-nil manager.  
- **Rust services** (flowgger, trapd, zen, otel, rperf, etc.): add async tests that instantiate `config_bootstrap::Bootstrap` with `CONFIG_SOURCE=kv` and mock `kvutil::KvClient`. Ensure `Bootstrap::new` succeeds and `load()` attempts a KV overlay instead of silently falling back to files.
- **Datasvc RBAC check**: table-driven unit test in `pkg/datasvc/rbac_test.go` to confirm every service certificate from `config/service_descriptors` has an entry granting at least `writer` role. Fail if a new descriptor is added without a matching RBAC rule.

## 2. Compose Smoke Tests

- Introduce a lightweight GitHub Action (or Buildkite job) that runs on every PR touching `cmd/` or `docker/compose/`. Steps:
  1. `docker compose up datasvc nats -d`.
  2. For each KV-aware service, run `./cmd/tools/config-sync --service <name> --output /tmp/foo --template docker/compose/<service>.docker.json|toml` to seed KV.
  3. `docker compose up --exit-code-from <service> <service>` to ensure the container reaches its health check without `KV store not initialized` errors.  
- Cache Bazel layers to keep runtime manageable; gate the matrix to the services touched by the PR (use `paths` filters).

## 3. Template/Key Validation

- Add a Go utility under `cmd/tools/kv-validate` that:
  - Lists every descriptor from `pkg/config/registry`.
  - Reads `config/` or `docker/compose/*.json|toml` defaults.
  - Hits `http://localhost:50057` (datasvc) to confirm `config/<service>` exists after `docker compose up`.
- Wire it into CI after the compose smoke test. Fail the job if any required key is missing; this prevents silent template regressions.

## 4. RBAC Drift Detection

- Write a script (Bash + `jq`) that parses:
  - `docker/compose/datasvc.docker.json`
  - `helm/serviceradar/files/serviceradar-config.yaml`
  - `k8s/demo/base/serviceradar-config.yaml`
  - systemd packaging configs
- Compare the list of identities to `pkg/config/registry.go`. Fail CI if a descriptor has `CONFIG_SOURCE=kv` but lacks writer access in any deployment mode.

## 5. Full Stack Watchdog (Nightly)

- Nightly workflow to run `docker compose up -d`, wait for health checks, then:
  - `docker compose exec serviceradar-tools nats-kv ls config`
  - `docker compose exec serviceradar-tools nats-kv get config/<service>`
  - Verify each service reports `KV update detected` at least once in its logs.
- Archive logs + KV snapshots as artifacts for forensic diffing.

## 6. Release Checklist Hook

- Extend `scripts/cut-release.sh` to verify:
  - `config-sync` successfully seeds every descriptor using the templates present in the release branch.
  - Datasvc RBAC contains the identities we’re about to ship (preventing post-release mapper-style issues).
- Fail the release script when the check breaks; force maintainers to fix KV before tagging.

## Ownership & Next Actions

1. **Mapper team**: add the Go unit test + docker compose smoke test job (target week 1).  
2. **Rust platform**: port flowgger/trapd/zen to the new bootstrap tests (target week 2).  
3. **Infra**: build the RBAC diff + nightly watchdog workflows (target week 3).  
4. **Release eng**: extend `cut-release.sh` once the validators exist (target week 4).

Once these land, any PR that drops KV wiring will fail before it’s merged, and nightly jobs will alert us if GHCR images regress after the fact.
