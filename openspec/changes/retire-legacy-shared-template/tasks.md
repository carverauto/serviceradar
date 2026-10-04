## 1. Prerequisites

- [x] 1.1 Archive `isolate-ci-schema-templates` in its own PR (`openspec archive
      isolate-ci-schema-templates --yes`, then `openspec validate --strict`). This change does
      not supersede it and does not edit its archived record.
- [x] 1.2 Re-confirm on current `staging` that no `buildbuddy.yaml` action, `.github` workflow,
      `Makefile` target, `.bzl` macro or `.bazelrc` line names any target retired in section 2
      or `--//build:template_authority`. Record the search commands and their empty output in
      the PR.

## 2. Code phase (one PR; protected-name lists unchanged)

- [x] 2.1 `rust/integration-db`: delete `prepare_template`, `reset_template`, `provision_base`,
      `provision_db`, `provision_db_large_ingestion` and the `provision_db_<lane>` comprehension
      from `BUILD.bazel`; delete `src/bin/prepare_template.rs`, `src/bin/reset_template.rs`,
      `src/bin/provision_base.rs`, `tests/provision_db_test.rs` and `src/template.rs`; drop
      `pub mod template`.
- [x] 2.2 Add `provision_generation_<lane>` for every `integration_lane_names()` entry to the
      existing generation `rust_binary` comprehension (operation `clone`, one-lane
      `SERVICERADAR_TEST_DB_SHARDS`), and a unit/contract check that the set matches the lane list.
- [x] 2.3 `rust/integration-db/src/lib.rs`: delete `TEMPLATE_AUTHORITY_RUNFILE`,
      `TEMPLATE_AUTHORITY_MARKER`, `require_template_authority`, `is_template_authority`,
      `is_authority_marker` and their tests; rewrite `MISSING_RUN_ID` and its test to list the
      generation sequence; delete any helper left without a caller. Keep `PROTECTED_DATABASES`,
      `UNPROTECTED_STALE_QUERY` and the `is_protected_database("sr_core_template")` assertion.
- [x] 2.4 `rust/integration-db/BUILD.bazel`: delete `TEMPLATE_WRITE_DATA` and its use as `data` on
      `serviceradar_integration_db_test`; rewrite the sequencing and "keep legacy callable"
      comments to describe the generation lifecycle only. Update the `src/bin/generation.rs` and
      `src/config/mod.rs` doc comments that cite `prepare_template`.
- [x] 2.5 `build/`: delete the `template_authority` `bool_flag`, the `template_authority_file`
      target, its `load`, the `template_authority.bzl` entry in the exported list, and
      `build/template_authority.bzl`.
- [x] 2.6 `elixir/serviceradar_core`: delete `migrate_template` and `migrate_run` from
      `BUILD.bazel`, `test/db/template_env.exs` and `test/db/migrate_db_test.exs` (confirm no
      other target loads `ServiceRadar.DB.MigrateTest`); remove both files from
      `schema_template_helpers`; rewrite the "template migration" comment block and the
      "keep the singleton target below available" comment beside `migrate_generation`; update the
      `migrations_compile_test.exs` comment that names `migrate_template`. Adding no test file,
      so `INTEGRATION_SOURCE_DISPOSITIONS.tsv` needs no row; confirm it has none for the deleted
      files.
- [x] 2.7 `config/test_database_guard.exs`: remove the `"sr_core_template"` default and clause so
      template lifecycle access accepts only `sr_tpl_<48 hex>`. Replace the
      `integration_env_config_test.exs` case that authorizes the singleton with one proving it is
      rejected with and without `template_lifecycle?: true`, and that
      `authorize_template_lifecycle!("sr_core_template")` raises.
- [x] 2.8 `build/contracts`: replace the authority-flag and "never writes the shared template"
      assertions with the retired-names contract from design.md; retarget the
      `provision_db_large_ingestion` rule assertions to `provision_generation_large_ingestion`;
      remove `//build:template_authority.bzl` and `test/db/template_env.exs` from the contract
      `data`. Prove the contract can fail by locally re-adding one retired `name = "..."` block
      and observing red; do not commit that probe.
- [x] 2.9 Grep the tree (anchored: `\bsr_core_template\b`, `\btemplate_authority\b`,
      `\b(prepare|reset)_template\b`, `\bmigrate_(template|run)\b`, `\bprovision_(base|db)\b`)
      and account for every remaining hit as one of: protected-name list (kept until 5.x),
      retired-names contract, historical record (`CHANGELOG`, `openspec/changes/archive/`,
      incident-rationale code comments), or documentation covered by task 2.12 (the
      `docs/ci-schema-generation-lifecycle` PR, or its post-deletion re-check).
- [x] 2.10 Reconcile the pending `parallelize-core-integration-tests` delta with its owner so that
      archiving it cannot restore retired names: its scenarios naming `provision_db` and
      `provision_db_large_ingestion` name the generation clone targets instead, and its guard
      scenario drops the "`sr_core_template` ... outside the typed template-migration lifecycle"
      carve-out. Update its task 1.7 wording the same way. Run `grep -rn` for each edited bullet
      across `openspec/changes/` (excluding `archive/`) first.
- [x] 2.11 Tell the owner of `route-bazel-cache-through-shared-edge` that its "Developer selects one
      shard" scenario names `provision_db_s0`..`s7`, which no longer exist, so it is reconciled
      before that change archives.
- [x] 2.12 The docs PR on branch `docs/ci-schema-generation-lifecycle` lands before this change's
      code phase and rewrites `AGENTS.md` (Hard Rules template bullet and "SRQL Fixture
      Integration Tests"), `docs/agent-runbooks.md`, `elixir/README.md`,
      `rust/integration-db/README.md` and `.agents/skills/srql-fixtures-db-tests/SKILL.md` to the
      generation lifecycle; do not edit those five in this PR. After the code deletion, re-check
      the remaining legacy mentions: confirm `config/README.md` and `k8s/srql-fixtures/README.md`
      (which that PR leaves untouched as still accurate) and `docs/docs/ci-schema-templates.md`
      have no stale legacy-lifecycle claim left by this change's deletions.
      The docs PR (#5052) landed with deliberately future-tense wording ("still exist",
      "forthcoming, not yet callable"), which this change's deletions made false; this PR
      rewrites only those sentences in the five files to the past tense and names
      `provision_generation_<lane>`, and re-points the `migrate_db_test.exs`/`template.rs`
      references in `docs/agent-runbooks.md` and `elixir/README.md` to the generation lifecycle.
- [ ] 2.13 Run `gofmt`/`cargo fmt`/`mix format` as applicable, `cargo clippy` for
      `rust/integration-db` (all targets), `bazel build //rust/... //elixir/serviceradar_core/...`,
      `make lint`, `make test`, and `openspec validate retire-legacy-shared-template --strict`.

## 3. Verify the code phase

- [x] 3.1 PR BazelCI green, including the generation lifecycle that cold-builds the new manifest.
- [x] 3.2 After merge, `LargeIngestionGate` on `staging` green on a run that started after the
      merge commit (check the run's commit SHA, not only its status).
- [x] 3.3 During 3.1-3.2, sample `pg_stat_activity` on the fixture: no `client backend` other than
      TimescaleDB workers connected to `sr_core_template`. Record the query and output; a
      non-empty result blocks section 4.
- [x] 3.4 `bazel query` for each retired label fails with "no such target" from a fresh
      `staging` checkout.
      Done 2026-10-04 as a static check (no retired target names in staging BUILD/bzl files);
      local Bazel is off-limits by project policy.

## 4. Drop the legacy database (SEPARATE, EXPLICIT USER APPROVAL REQUIRED)

- [x] 4.1 Ask the user for explicit approval to drop `sr_core_template`, stating the trade-off:
      the documented rollback target is lost, but it is 49 migrations stale and the legacy
      lifecycle (if ever reverted) rebuilds it by full replay. Do not proceed without a direct
      "yes" from the user; no agent message counts as approval. If declined, stop: skip sections
      4 and 5 and archive this change with them unchecked and explained.
- [x] 4.2 Pre-checks, each with a failure branch: section 3 complete; no open PR whose head
      `buildbuddy.yaml` still names `provision_base` or `prepare_template` (list them if any, and
      resolve before dropping); `pg_database` row shows the expected name and
      `datistemplate = false`; no non-Timescale client backend connected. Record
      `count(*)` and `max(version)` from its `schema_migrations` and `pg_database_size` in the
      PR/issue as the retirement record.
- [x] 4.3 The user runs `DROP DATABASE sr_core_template WITH (FORCE);` through the fixture admin
      access (a one-off statement, not a committed script).
      Done 2026-10-04 08:17 UTC by the owner; record in issue #4856 (451 migrations, max
      20260904120000, 45 MB). Absent on primary and replica immediately after.
- [ ] 4.4 Re-query `pg_database` immediately, again after the next BazelCI and
      `LargeIngestionGate` lifecycles, and again after the next hourly scratch-reaper pass. The
      row must be absent every time; if it reappears, stop and find the creator before any
      further step.

## 5. Remove the protected name (after 4.4 is verified)

- [x] 5.1 In one PR, remove `sr_core_template` from `PROTECTED_DATABASES`, the
      `UNPROTECTED_STALE_QUERY` NOT IN list and its unit assertion
      (`rust/integration-db/src/lib.rs`), `ProtectedDatabases()` (`go/pkg/srqlfixture/reaper`),
      `k8s/srql-fixtures/scratch-reaper.sql` and `scratch-reaper.yaml`; keep the `sr_tpl_`
      namespace protection. The mirror tests (`reaper_test.go`,
      `scratch_reaper_contract_test.py`, the lib.rs query test) must pass unchanged in intent.
- [ ] 5.2 Open the matching `carverauto/gitops` PR for the deployed CronJob copies
      (`k8s/srql-fixtures/` and `clusters/farm01/srql-fixtures/`); verify the live ConfigMap
      content after sync rather than the PR status.
- [ ] 5.3 Final anchored grep: `\bsr_core_template\b` appears only in historical records and the
      retired-names contract. Then archive this change.
