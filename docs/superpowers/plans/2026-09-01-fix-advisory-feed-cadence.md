# Advisory Feed Cadence and KEV Deduplication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix GitHub issue #4204 so advisory-feed jobs retain their configured cadence and unchanged KEV records do not rewrite the advisory corpus.

**Architecture:** Keep seed and reconciliation inserts unique across all incomplete Oban states, but build self-scheduled successors with the existing `ServiceRadar.Jobs.SelfScheduling` helper so an executing job cannot consume its own successor. Add a nullable persisted SHA-256 content hash for advisory records; timestamp-capable feeds continue comparing `modified_at`, while KEV feeds compare deterministic hashes of the persisted advisory and coordinate content.

**Tech Stack:** Elixir, Oban, Ecto/PostgreSQL, Ash, ExUnit, Bazel.

**Spec:** GitHub issue [#4204](https://github.com/carverauto/serviceradar/issues/4204) and the approved 2026-09-01 in-chat design.

## Global Constraints

- The branch starts at `github/staging` commit `2dce7ef742c3a7e0ea7b924fbb670a3063da3ff7`.
- Preserve `FeedWorker` seed uniqueness across `:incomplete` states; only successor inserts use `unique: [states: :scheduled]`.
- A completed feed run must leave exactly one non-conflicting scheduled successor at `Config.refresh_seconds(feed)`.
- Reconciliation must not enqueue an early duplicate when a valid scheduled successor exists.
- NVD and other timestamp-capable feeds continue using `modified_at`; a missing timestamp remains fail-open and must not be treated as unchanged.
- Only `cisa-kev` and `vulncheck-kev` may use content-hash comparison when `modified_at` is absent.
- The KEV hash covers every source-derived advisory field persisted by `Loader` plus every persisted coordinate field; it excludes loader-managed generation/current/timestamps.
- Coordinate order and map-key order must not change the KEV hash.
- A legacy KEV row with a null hash rewrites once to backfill the hash, then skips identical subsequent records.
- The inert-guard alarms only when stored rows have usable comparison state, so the KEV backfill is not reported as a guard failure; timestamp-capable guard failures still alarm.
- Do not add shell scripts. Use Bazel targets for tests and the repository-wide `make test` gate.
- Do not push directly to `staging`; push the feature branch with an explicit refspec.

### Local DataCase Test Environment

The guarded Bazel integration lanes are CI-only. Run focused `ServiceRadar.DataCase`
tests from `elixir/serviceradar_core` against the disposable workstation scratch
database below; continue to use Bazel for pure tests and the full unit gate.

- Database: `codex_feed4204_20260901_8432`
- Host/port: `192.168.10.31:30818`
- TLS server name: `srql-fixture-rw.srql-fixtures.svc.cluster.local`
- CA file: `/private/tmp/srql-fixture-ca-feed4204.crt`
- Credential secret: `srql-test-admin-credentials` in namespace `srql-fixtures`

Retrieve the username and password into shell-local variables with `kubectl`, URL
encode the password with `jq`, and invoke `mix` with these environment values:

```bash
SERVICERADAR_TEST_DATABASE_URL="postgres://${sr_user}:${sr_pass_enc}@192.168.10.31:30818/codex_feed4204_20260901_8432?sslmode=verify-full" \
SRQL_TEST_DATABASE_SERVER_NAME=srql-fixture-rw.srql-fixtures.svc.cluster.local \
SRQL_TEST_DATABASE_CA_CERT_FILE=/private/tmp/srql-fixture-ca-feed4204.crt \
SERVICERADAR_TEST_DATABASE_POOL_SIZE=1 \
SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS=900000 \
SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS=10000 \
SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS=10000 \
SERVICERADAR_TEST_SANDBOX_MODE=shared \
MIX_ENV=test mix test <test-path>
```

Never print the credentials. Drop only this exact scratch database after all focused
DataCase verification is complete.

---

### Task 1: Preserve FeedWorker successors and reconciliation cadence

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/advisory_feeds/feed_worker.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/inventory/advisory_feeds/feed_worker_scheduling_test.exs`
- Modify: `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`
- Modify: `elixir/serviceradar_core/test/serviceradar/jobs/self_scheduling_worker_uniqueness_test.exs`

**Interfaces:**
- Consumes: `ServiceRadar.Jobs.SelfScheduling.successor_changeset/3`.
- Produces: `FeedWorker.schedule_next/1` inserts a successor changeset whose `unique.states` is exactly `[:scheduled]`, retaining `%{"feed" => feed}` and the configured delay.

- [ ] **Step 1: Write the failing behavioral successor test**

Create a `ServiceRadar.DataCase` test that starts core once, seeds feed definitions, enables `nist-nvd2`, sets its refresh interval to the literal `7_200`, inserts a real `Oban.Job` row in `executing`, disables the NIST sub-gate, and calls the real `FeedWorker.perform/1` path:

```elixir
test "an executing feed job leaves one scheduled successor at the configured cadence" do
  executing = insert_executing_job!("nist-nvd2")

  assert :ok = FeedWorker.perform(%{executing | args: %{"feed" => "nist-nvd2"}})

  successors =
    Repo.all(
      from(job in Oban.Job,
        where: job.worker == ^inspect(FeedWorker),
        where: fragment("?->>'feed' = ?", job.args, "nist-nvd2"),
        where: job.id != ^executing.id and job.state == "scheduled"
      )
    )

  assert [%Oban.Job{conflict?: false, args: %{"feed" => "nist-nvd2"}} = successor] =
           successors

  delay = DateTime.diff(successor.scheduled_at, DateTime.utc_now())
  assert delay in 7_195..7_200
end
```

The test setup must restore all application environment and delete only its `FeedWorker` jobs in `on_exit/1`.

- [ ] **Step 2: Write the reconciliation regression test**

Insert one valid future `cisa-kev` scheduled job, call `FeedWorker.ensure_scheduled/0`, and assert the exact `(worker, feed)` query still returns one job with the same id and a scheduled time at least 3,500 seconds in the future:

```elixir
assert {:ok, :scheduled} = FeedWorker.ensure_scheduled()
assert [%Oban.Job{id: ^future_id, state: "scheduled"}] = jobs_for("cisa-kev")
assert DateTime.diff(hd(jobs_for("cisa-kev")).scheduled_at, DateTime.utc_now()) > 3_500
```

This catches a reconciliation implementation that ignores an existing future successor and inserts the five-second seed.

- [ ] **Step 3: Audit the new DataCase test disposition**

Add an alphabetically placed TSV row classifying the new test as `data_case`, `async: false`, with caller-owned Oban inserts and no autonomous queue execution. The description must explain why the test safely owns its jobs.

- [ ] **Step 4: Run the focused test and observe the expected failure**

From `elixir/serviceradar_core`, run the focused test with the Local DataCase Test
Environment above:

```bash
MIX_ENV=test mix test test/serviceradar/inventory/advisory_feeds/feed_worker_scheduling_test.exs
```

Expected before the production fix: the successor assertion fails because the insert conflicts with the executing job and no second scheduled row exists. The reconciliation assertion may already pass.

- [ ] **Step 5: Route successor insertion through the shared helper**

Add the alias:

```elixir
alias ServiceRadar.Jobs.SelfScheduling
```

Replace only the successor construction:

```elixir
defp schedule_next(feed) do
  if Config.feed_enabled?(feed) do
    seconds = Config.refresh_seconds(feed)

    _ =
      feed
      |> then(&%{feed: &1})
      |> then(&SelfScheduling.successor_changeset(__MODULE__, &1, seconds))
      |> ObanSupport.safe_insert()
  end

  :ok
end
```

Do not change the worker-level `unique: [period: :infinity, keys: [:feed], states: :incomplete]`; seed and reconciliation inserts depend on it.

- [ ] **Step 6: Register FeedWorker in the self-scheduling contract inventory**

Add `ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker` to `@workers` beside `StagingCleanupWorker`. This is inventory coverage; the real regression protection remains the database behavioral test.

- [ ] **Step 7: Run the focused scheduling and contract tests**

Run the database-backed scheduling test through the Local DataCase Test Environment,
then run the pure contract test with Bazel:

```bash
MIX_ENV=test mix test test/serviceradar/inventory/advisory_feeds/feed_worker_scheduling_test.exs
bazel test //elixir/serviceradar_core:unit_tests_serviceradar_other --test_filter=ServiceRadar.Jobs.SelfSchedulingWorkerUniquenessTest --test_output=errors
```

Expected: both test modules pass; the scheduling test reports one future successor and no early reconciliation duplicate.

- [ ] **Step 8: Format and commit Task 1**

Run `mix format` on the modified `.ex` and `.exs` files, re-run Step 7, then commit:

```bash
git commit -m "fix(feeds): preserve advisory feed successors"
```

---

### Task 2: Persist stable KEV comparison hashes and retain the guard

**Files:**
- Create: `elixir/serviceradar_core/priv/repo/migrations/20260901120000_add_advisory_content_hash.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/vulnerability_advisory.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/advisory_feeds/loader.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/advisory_feeds/feed_worker.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/advisory_feeds/loader_test.exs`
- Modify: `elixir/serviceradar_core/test/integration/advisory_feed_loader_integration_test.exs`

**Interfaces:**
- Produces: `Loader.content_hash/1 :: String.t()` returning 64 lowercase SHA-256 hex characters.
- Produces: `Loader.existing_comparison_state/2 :: %{optional(String.t()) => %{modified_at: DateTime.t() | nil, content_hash: String.t() | nil}}`.
- Produces: `Loader.unchanged_advisory?/3` with `comparison: :modified_at | :content_hash`; the existing two-argument form defaults to `:modified_at` for timestamp safety.
- Produces: `Loader.comparable_count/2` so `FeedWorker` can distinguish a legacy KEV backfill from an inert guard.

- [ ] **Step 1: Add failing pure hash and comparison tests**

Extend `LoaderTest` with literal KEV records that prove:

```elixir
assert Loader.content_hash(kev_record()) =~ ~r/^[0-9a-f]{64}$/
assert Loader.content_hash(kev_record()) == Loader.content_hash(reordered_kev_record())
refute Loader.content_hash(kev_record()) == Loader.content_hash(changed_description_record())
refute Loader.content_hash(kev_record()) == Loader.content_hash(changed_coordinate_record())
```

`reordered_kev_record/0` must independently reconstruct the maps and reverse the coordinate list; it must not call production normalization. Add comparison assertions:

```elixir
state = %{"CVE-2026-0001" => %{modified_at: nil, content_hash: Loader.content_hash(record)}}
assert Loader.unchanged_advisory?(record, state, comparison: :content_hash)
refute Loader.unchanged_advisory?(changed_record, state, comparison: :content_hash)
refute Loader.unchanged_advisory?(record, %{"CVE-2026-0001" => %{modified_at: nil, content_hash: nil}}, comparison: :content_hash)
```

Retain explicit tests showing `comparison: :modified_at` never skips when either timestamp is nil, even if a matching content hash is present.

- [ ] **Step 2: Add failing database round-trip tests**

Extend the existing loader integration test with a real KEV-shaped record whose `modified_at` is nil. Assert first load writes one row, second identical load skips one row and does not change advisory `updated_at`, then a changed description or coordinate rewrites exactly one row. Add a legacy-row case by nulling `content_hash` between runs: the next run must rewrite once and the following run must skip.

- [ ] **Step 3: Run the focused tests and observe the expected failures**

Run:

```bash
bazel test //elixir/serviceradar_core:unit_tests_serviceradar_inventory --test_filter=ServiceRadar.Inventory.AdvisoryFeeds.LoaderTest --test_output=errors
MIX_ENV=test mix test test/integration/advisory_feed_loader_integration_test.exs
```

Run the second command through the Local DataCase Test Environment.

Expected before implementation: compilation fails because `Loader.content_hash/1`, `existing_comparison_state/2`, and content-hash comparison do not exist; no production code should be changed before this red result is recorded.

- [ ] **Step 4: Add nullable persistence for the hash**

Create a reversible migration:

```elixir
defmodule ServiceRadar.Repo.Migrations.AddAdvisoryContentHash do
  use Ecto.Migration

  def change do
    alter table(:vulnerability_advisories, prefix: "platform") do
      add :content_hash, :text
    end
  end
end
```

This is a post-baseline migration: the frozen baseline must remain unchanged unless it is fully regenerated with an advanced `included_through` marker. Add a public nullable `:content_hash` string attribute to `VulnerabilityAdvisory`, its accepted upsert fields, and its replacement fields. Do not add an index; reads are scoped by `(provider, feed_key, current)` and return the hash as payload.

- [ ] **Step 5: Implement deterministic record hashing**

In `Loader`, define explicit advisory and coordinate field lists matching `advisory_row/5` and `coordinate_row/6`. Build a tuple from those source-derived values, encode coordinate tuples with `:erlang.term_to_binary(..., [:deterministic])`, sort those binaries, then hash the deterministic payload:

```elixir
payload
|> :erlang.term_to_binary([:deterministic])
|> then(&:crypto.hash(:sha256, &1))
|> Base.encode16(case: :lower)
```

Exclude `generation`, `current`, `inserted_at`, and `updated_at`. Include `raw`, `metadata`, references, all normalized advisory fields, and all coordinate fields persisted by `Loader`.

- [ ] **Step 6: Load and compare stored state without weakening NVD**

Replace the timestamp-only live-row lookup used by `load_stream/2` with a schemaless query returning both `modified_at` (cast with `type(..., :utc_datetime_usec)`) and `content_hash`. Choose comparison mode from `feed_key`: `:content_hash` only for `cisa-kev` and `vulncheck-kev`; `:modified_at` for every other feed.

Persist `content_hash(record)` only for `cisa-kev` and `vulncheck-kev`; keep the nullable key set to `nil` for timestamp-comparison feeds so large NVD loads do not hash payloads the guard will never read. Add `:content_hash` to the conflict replacement list. A null stored hash must return `false` from the content comparison so a legacy KEV row is rewritten once.

- [ ] **Step 7: Make the inert guard capability-aware**

Pass `Loader.comparable_count(feed_key, existing_state)` to `warn_if_guard_inert/3` instead of raw map size. For KEV, count only non-null stored hashes; for other feeds, count only non-null timestamps. Keep the existing alarm condition and message once `comparable_count > 0`, preserving the timestamp-capable failure detector while avoiding an alarm during legacy KEV backfill.

- [ ] **Step 8: Run focused tests and migration/schema gates**

Run:

```bash
bazel test //elixir/serviceradar_core:unit_tests_serviceradar_inventory --test_filter='ServiceRadar.Inventory.AdvisoryFeeds.LoaderTest|ServiceRadar.Inventory.AdvisoryFeeds.FeedWorkerSchedulingTest' --test_output=errors
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix test test/serviceradar/inventory/advisory_feeds/feed_worker_scheduling_test.exs test/integration/advisory_feed_loader_integration_test.exs
bazel test //elixir/serviceradar_core:unit_tests_serviceradar_other --test_filter='ServiceRadar.Repo.MigrationsCompileTest|ServiceRadar.Postgres.SchemaSqlTest' --test_output=errors
```

Run both `mix` commands through the Local DataCase Test Environment. The first Bazel
command covers the pure loader unit tests; the scheduling test remains in the Mix
command because its disposition is database-backed.

Expected: all commands pass and each command has an explicit nonzero failure exit if its named test cannot run.

- [ ] **Step 9: Format and commit Task 2**

Run `mix format` on changed Elixir sources and the migration, re-run Step 8, then commit:

```bash
git commit -m "fix(feeds): skip unchanged KEV advisories"
```

---

### Task 3: Whole-branch verification and delivery

**Files:**
- Modify only if verification exposes a defect in Tasks 1-2.

**Interfaces:**
- Consumes: both task commits.
- Produces: a reviewed feature branch ready for an explicit-refspec push and GitHub pull request.

- [ ] **Step 1: Verify formatting and focused behavior**

Run `mix format --check-formatted` on every changed `.ex`/`.exs` file, then re-run all focused Bazel commands from Tasks 1 and 2. Treat a test command that selects zero tests as failure and correct the target/filter.

- [ ] **Step 2: Run the repository-wide unit gate**

Run:

```bash
make test
```

Expected: exit 0 after Bazel reports the repository unit target set passed. Read and report any failure; do not claim success from an invocation that never reached remote execution.

- [ ] **Step 3: Review the complete branch diff**

Review `github/staging...HEAD` for issue #4204 acceptance coverage, migration/baseline parity, query scoping, deterministic hashing, and unrelated changes. Fix and re-run affected tests for any load-bearing finding.

- [ ] **Step 4: Push with an explicit refspec and open the PR**

Push only:

```bash
git push github codex/fix-4204-advisory-feed-cadence:refs/heads/codex/fix-4204-advisory-feed-cadence
```

Open a GitHub PR against `staging` that references and closes #4204, includes focused and full test evidence, and notes the one-run KEV hash backfill behavior.
