# Sweep Diagnostics Write Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the sweep coverage data that is currently discarded at ingest, and roll it up daily so sweep attribution survives the 7 day raw retention window.

**Architecture:** A pure `PortCoverage` module derives the set of ports a sweep actually attempted from the agent payload the ingestor already receives. `sweep_host_results` gains `scanned_ports` plus denormalized `agent_id` and `sweep_group_id`, so a result carries its own vantage point and group identity and closed ports become `scanned_ports` minus `open_ports`. A daily Oban worker rolls those rows into `platform.sweep_coverage_daily`, keyed by day, device, sweep group and agent, and the existing cleanup worker learns to refuse to delete a day that has not been rolled up.

**Tech Stack:** Elixir, Ash/AshPostgres, Ecto/PostgreSQL, Oban, ExUnit, Bazel, OpenSpec.

**Spec:** `openspec/changes/add-sweep-diagnostics-srql-entities/`

**Scope note:** This is plan 1 of 2. It ships the collection half and is independently valuable: every day it is deployed before plan 2 is a day of sweep history that would otherwise be lost to the 7 day window. Plan 2 adds the seven SRQL entities that read this data. Do not add SRQL entities, catalog entries or MCP docs in this plan.

## Global Constraints

- Migrations are hand-written Ecto migrations under `elixir/serviceradar_core/priv/repo/migrations/`. `priv/resource_snapshots/` is absent and gitignored, so `mix ash.codegen` would emit a whole-application migration. Do not run it.
- All tables, indexes and constraints live in the `platform` schema. Pass `prefix: "platform"` explicitly; never reference `public`.
- No new direct-to-database metric path. This plan touches sweep results, which are not metrics, and adds no metric write.
- No shell scripts. Anything that needs running is a Bazel target or an Oban worker.
- Database-backed tests carry `@moduletag :integration`, use `ServiceRadar.DataCase, async: false`, and MUST be registered in `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`. Database-free tests carry `@moduletag :db_free`.
- Run database-backed tests through the guarded Bazel lifecycle described by the `srql-fixtures-db-tests` skill: sweep, prepare template, migrate, provision, test, teardown, with one run id for the whole sequence. Never leave a shard provisioned after a red run.
- `scanned_ports` records what the agent attempted, taken only from the payload. Never seed it from the sweep group's configured ports: the requested set is already visible on the group, and merging the two destroys the requested-versus-attempted distinction this whole change exists to provide.
- No agent, proto or wire-format change. The per-port data is already in the payload and is dropped at ingest today.
- Historical rows are not backfilled. Rows written before the migration keep an empty `scanned_ports`, which reads correctly as "coverage unknown", not as "nothing was scanned".
- Use strict TDD: write the failing test, run it and read the actual failure text, then write the minimum production code. A test that cannot fail is not a test.

---

## Task 1: Pure port-coverage derivation

Extract the derivation as a pure module so it can be tested without a database, following the `agent_assignment.ex` precedent.

**Files:**

- Create: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/port_coverage.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/port_coverage_test.exs`

**Interfaces:**

- Consumes: nothing from earlier tasks.
- Produces: `ServiceRadar.SweepJobs.PortCoverage.scanned_ports(map()) :: [pos_integer()]` — sorted, deduplicated, 1..65535 only. Task 2 calls this.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/sweep_jobs/port_coverage_test.exs`:

```elixir
defmodule ServiceRadar.SweepJobs.PortCoverageTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.PortCoverage

  @moduletag :db_free

  describe "scanned_ports/1" do
    test "records every attempted port, open or not" do
      result = %{
        "port_results" => [
          %{"port" => 443, "available" => true},
          %{"port" => 3001, "available" => false},
          %{"port" => 4502, "available" => false}
        ]
      }

      assert PortCoverage.scanned_ports(result) == [443, 3001, 4502]
    end

    test "a host that refuses every port still reports coverage" do
      result = %{
        "port_results" => [
          %{"port" => 3001, "available" => false},
          %{"port" => 4502, "available" => false}
        ]
      }

      assert PortCoverage.scanned_ports(result) == [3001, 4502]
    end

    test "an ICMP-only result scans no ports" do
      assert PortCoverage.scanned_ports(%{"icmp_available" => true}) == []
    end

    test "an open port is always a scanned port even without port_results" do
      assert PortCoverage.scanned_ports(%{"tcp_ports_open" => [22, 80]}) == [22, 80]
    end

    test "accepts the camelCase and legacy payload keys" do
      assert PortCoverage.scanned_ports(%{"portScanResults" => [%{"port" => 22}]}) == [22]
      assert PortCoverage.scanned_ports(%{"port_scan_results" => [%{"port" => 23}]}) == [23]
    end

    test "parses string ports and rejects garbage and out-of-range values" do
      result = %{
        "port_results" => [
          %{"port" => "443"},
          %{"port" => "not-a-port"},
          %{"port" => 0},
          %{"port" => 65_536},
          %{"port" => nil},
          %{"available" => true}
        ]
      }

      assert PortCoverage.scanned_ports(result) == [443]
    end

    test "deduplicates and sorts" do
      result = %{
        "port_results" => [%{"port" => 443}, %{"port" => 22}, %{"port" => 443}],
        "tcp_ports_open" => [22]
      }

      assert PortCoverage.scanned_ports(result) == [22, 443]
    end

    test "tolerates a malformed port_results payload" do
      assert PortCoverage.scanned_ports(%{"port_results" => "unexpected"}) == []
      assert PortCoverage.scanned_ports(%{}) == []
    end
  end
end
```

- [ ] **Step 2: Run the test and read the failure**

```bash
cd elixir/serviceradar_core && mix test test/serviceradar/sweep_jobs/port_coverage_test.exs
```

Expected: compile error, `ServiceRadar.SweepJobs.PortCoverage is not available`. Read the actual text before continuing; a different error means something else is wrong.

- [ ] **Step 3: Write the module**

Create `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/port_coverage.ex`:

```elixir
defmodule ServiceRadar.SweepJobs.PortCoverage do
  @moduledoc """
  Pure derivation of per-host port coverage from an agent sweep result.

  `open_ports` records the ports that answered. `scanned_ports` records every
  port the sweep attempted, so a refused port is distinguishable from a port
  that was never tried at all. Closed and no-response ports are not stored:
  they are `scanned_ports` minus `open_ports`, derived at read time.

  Coverage is taken only from the agent payload. It is deliberately not seeded
  from the sweep group's configured ports, because the configured set is what
  was requested and this value is what was attempted; merging them would erase
  the distinction.
  """

  @min_port 1
  @max_port 65_535

  @doc """
  Every port the agent reported attempting, sorted and deduplicated.

  Returns `[]` for an ICMP-only result or a payload with no port data.
  """
  @spec scanned_ports(map()) :: [pos_integer()]
  def scanned_ports(result) when is_map(result) do
    (reported_ports(result) ++ open_ports(result))
    |> Enum.map(&parse_port/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def scanned_ports(_result), do: []

  defp reported_ports(result) do
    case port_results(result) do
      entries when is_list(entries) -> Enum.map(entries, &entry_port/1)
      _ -> []
    end
  end

  defp port_results(result) do
    result["port_results"] || result["port_scan_results"] || result["portScanResults"]
  end

  defp entry_port(entry) when is_map(entry), do: entry["port"] || entry[:port]
  defp entry_port(_entry), do: nil

  # An open port was necessarily attempted, so it counts as coverage even when
  # the payload omits the per-port detail.
  defp open_ports(result) do
    case result["tcp_ports_open"] || result["tcpPortsOpen"] do
      ports when is_list(ports) -> ports
      _ -> []
    end
  end

  defp parse_port(value) when is_integer(value), do: valid_port(value)

  defp parse_port(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> valid_port(parsed)
      _ -> nil
    end
  end

  defp parse_port(_value), do: nil

  defp valid_port(port) when port >= @min_port and port <= @max_port, do: port
  defp valid_port(_port), do: nil
end
```

- [ ] **Step 4: Run the test and confirm it passes**

```bash
cd elixir/serviceradar_core && mix test test/serviceradar/sweep_jobs/port_coverage_test.exs
```

Expected: PASS, 8 tests, 0 failures.

- [ ] **Step 5: Mutation-check one assertion**

Temporarily change `valid_port(port) when port >= @min_port` to `port >= 0` and re-run. The out-of-range test MUST fail. Revert the change. A suite that stays green under this edit is not testing what you think.

- [ ] **Step 6: Register the database-free test and commit**

Add to `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` (tab-separated, six columns):

```
test/serviceradar/sweep_jobs/port_coverage_test.exs	ServiceRadar.SweepJobs.PortCoverageTest	plain	async	db_free	Pure derivation over payload maps; no repo, no application processes.
```

```bash
cd elixir/serviceradar_core && mix format lib/serviceradar/sweep_jobs/port_coverage.ex test/serviceradar/sweep_jobs/port_coverage_test.exs
git add lib/serviceradar/sweep_jobs/port_coverage.ex test/serviceradar/sweep_jobs/port_coverage_test.exs test/INTEGRATION_SOURCE_DISPOSITIONS.tsv
git commit -m "feat(sweep): derive attempted port coverage from agent payload"
```

---

## Task 2: Persist coverage and result identity

**Files:**

- Create: `elixir/serviceradar_core/priv/repo/migrations/20260902120000_add_sweep_host_result_coverage.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_host_result.ex` (`@result_fields`, attributes block)
- Modify: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex` (`build_host_results/3` becomes `/4`, `build_host_record/5` becomes `/6`, the `on_conflict_query`)
- Modify: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_results_ingestor_test.exs`

**Interfaces:**

- Consumes: `PortCoverage.scanned_ports/1` from Task 1.
- Produces: `sweep_host_results.scanned_ports`, `.agent_id`, `.sweep_group_id`. Task 3 aggregates these three columns.
- Produces: `SweepResultsIngestor.build_host_results(results, execution_id, device_map, context \\ [])` where `context` is a keyword list accepting `:agent_id` and `:sweep_group_id`. The default keeps the ten existing 3-arity test call sites compiling unchanged.

- [ ] **Step 1: Write the failing ingestor test**

Append to `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_results_ingestor_test.exs`, inside the existing `describe "build_host_results/3"` block:

```elixir
    test "records scanned ports alongside open ports" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host" => "192.168.1.10",
          "available" => true,
          "port_results" => [
            %{"port" => 443, "available" => true},
            %{"port" => 3001, "available" => false},
            %{"port" => 4502, "available" => false}
          ]
        }
      ]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.open_ports == [443]
      assert record.scanned_ports == [443, 3001, 4502]
    end

    test "a host refusing every port is distinguishable from an ICMP-only host" do
      execution_id = Ash.UUID.generate()

      results = [
        %{
          "host" => "192.168.1.11",
          "available" => false,
          "port_results" => [%{"port" => 3001, "available" => false}]
        },
        %{"host" => "192.168.1.12", "available" => true, "icmp_available" => true}
      ]

      {[refused, icmp_only], _stats} =
        SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert refused.open_ports == []
      assert refused.scanned_ports == [3001]
      assert icmp_only.open_ports == []
      assert icmp_only.scanned_ports == []
    end

    test "stamps the vantage point and sweep group on the result" do
      execution_id = Ash.UUID.generate()
      group_id = Ash.UUID.generate()

      results = [%{"host" => "192.168.1.13", "available" => true}]

      {[record], _stats} =
        SweepResultsIngestor.build_host_results(results, execution_id, %{},
          agent_id: "agent-a",
          sweep_group_id: group_id
        )

      assert record.agent_id == "agent-a"
      assert record.sweep_group_id == group_id
    end

    test "omitted context leaves identity nil rather than crashing" do
      execution_id = Ash.UUID.generate()
      results = [%{"host" => "192.168.1.14", "available" => true}]

      {[record], _stats} = SweepResultsIngestor.build_host_results(results, execution_id, %{})

      assert record.agent_id == nil
      assert record.sweep_group_id == nil
    end
```

- [ ] **Step 2: Run the test and read the failure**

```bash
cd elixir/serviceradar_core && mix test test/serviceradar/sweep_jobs/sweep_results_ingestor_test.exs
```

Expected: `KeyError` on `:scanned_ports` for the first two, and a `BadArityError` or `UndefinedFunctionError` for `build_host_results/4`. Read the real text.

- [ ] **Step 3: Write the migration**

Create `elixir/serviceradar_core/priv/repo/migrations/20260902120000_add_sweep_host_result_coverage.exs`:

```elixir
defmodule ServiceRadar.Repo.Migrations.AddSweepHostResultCoverage do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:sweep_host_results, prefix: @prefix) do
      add :scanned_ports, {:array, :bigint}, null: false, default: []
      add :agent_id, :text
      add :sweep_group_id, :uuid
    end

    create index(:sweep_host_results, [:sweep_group_id, :inserted_at],
             prefix: @prefix,
             name: "sweep_host_results_group_inserted_idx",
             where: "sweep_group_id IS NOT NULL"
           )

    create index(:sweep_host_results, [:agent_id, :inserted_at],
             prefix: @prefix,
             name: "sweep_host_results_agent_inserted_idx",
             where: "agent_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:sweep_host_results, [:agent_id, :inserted_at],
                     prefix: @prefix,
                     name: "sweep_host_results_agent_inserted_idx"
                   )

    drop_if_exists index(:sweep_host_results, [:sweep_group_id, :inserted_at],
                     prefix: @prefix,
                     name: "sweep_host_results_group_inserted_idx"
                   )

    alter table(:sweep_host_results, prefix: @prefix) do
      remove :sweep_group_id
      remove :agent_id
      remove :scanned_ports
    end
  end
end
```

There is deliberately no backfill. An empty `scanned_ports` on a pre-migration row means "coverage unknown", which is honest; inventing coverage from today's group configuration would be a fabricated historical record.

- [ ] **Step 4: Add the attributes to the Ash resource**

In `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_host_result.ex`, extend `@result_fields` to include the three new fields:

```elixir
  @result_fields [
    :execution_id,
    :ip,
    :hostname,
    :status,
    :response_time_ms,
    :sweep_modes_results,
    :open_ports,
    :scanned_ports,
    :error_message,
    :device_id,
    :agent_id,
    :sweep_group_id
  ]
```

Then add three attributes immediately after the existing `open_ports` attribute:

```elixir
    attribute :scanned_ports, {:array, :integer} do
      allow_nil? false
      public? true
      default []
      description "Every TCP port the sweep attempted; closed ports are these minus open_ports"
    end

    attribute :agent_id, :string do
      allow_nil? true
      public? true
      description "Agent that produced this result, denormalized from the execution"
    end

    attribute :sweep_group_id, :uuid do
      allow_nil? true
      public? true
      description "Sweep group that produced this result, denormalized from the execution"
    end
```

- [ ] **Step 5: Thread coverage and identity through the ingestor**

In `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex`:

Add the alias near the other aliases at the top of the module:

```elixir
  alias ServiceRadar.SweepJobs.PortCoverage
```

Change `build_host_results/3` (currently at line 950) to take an optional context:

```elixir
  def build_host_results(results, execution_id, device_map, context \\ []) do
    agent_id = context[:agent_id]
    sweep_group_id = context[:sweep_group_id]

    initial_stats = %{
      hosts_total: 0,
      hosts_available: 0,
      hosts_failed: 0
    }

    {records, stats} =
      Enum.reduce(results, {[], initial_stats}, fn result, {acc, stats} ->
        ip = extract_ip(result)
        is_available = result_available?(result)
        status = host_status(result, is_available)
        device_id = device_id_for_ip(device_map, ip)

        record =
          build_host_record(result, execution_id, ip, status, device_id, {agent_id, sweep_group_id})

        updated_stats = update_host_stats(stats, is_available)

        {[record | acc], updated_stats}
      end)

    {Enum.reverse(records), stats}
  end
```

Change `build_host_record/5` (currently at line 1000) to stamp the three new fields:

```elixir
  defp build_host_record(result, execution_id, ip, status, device_id, {agent_id, sweep_group_id}) do
    # DB connection's search_path determines the schema
    %{
      id: Ash.UUID.generate(),
      execution_id: execution_id,
      ip: ip,
      hostname: result["hostname"],
      status: status,
      response_time_ms: response_time_ms(result),
      open_ports: open_ports(result),
      scanned_ports: PortCoverage.scanned_ports(result),
      sweep_modes_results: build_modes_results(result),
      device_id: device_id,
      agent_id: agent_id,
      sweep_group_id: sweep_group_id,
      error_message: result["error"],
      inserted_at: DateTime.utc_now()
    }
  end
```

At the production call site (currently line 676), pass the context the availability path already uses:

```elixir
    {host_results, stats} =
      build_host_results(results, execution_id, all_devices,
        agent_id: reporter_context.reporter_agent_id,
        sweep_group_id: reporter_context.resolved_group_id
      )
```

- [ ] **Step 6: Make the upsert merge instead of clobber**

In the same file, extend the `on_conflict_query` (currently near line 1190). The conflict target is `[:execution_id, :ip]` and the same host can be written more than once as progress batches arrive, which is exactly why `response_time_ms` already has preservation logic. Coverage must accumulate across those batches, and identity must not be nulled by a later batch that lacks context:

```elixir
    on_conflict_query =
      from(r in SweepHostResult,
        update: [
          set: [
            hostname: fragment("EXCLUDED.hostname"),
            status: fragment("EXCLUDED.status"),
            response_time_ms:
              fragment(
                "COALESCE(NULLIF(EXCLUDED.response_time_ms, 0), ?)",
                r.response_time_ms
              ),
            open_ports: fragment("EXCLUDED.open_ports"),
            scanned_ports:
              fragment(
                "ARRAY(SELECT DISTINCT u FROM unnest(COALESCE(?, '{}'::bigint[]) || COALESCE(EXCLUDED.scanned_ports, '{}'::bigint[])) AS u ORDER BY u)",
                r.scanned_ports
              ),
            sweep_modes_results: fragment("EXCLUDED.sweep_modes_results"),
            device_id: fragment("EXCLUDED.device_id"),
            agent_id: fragment("COALESCE(EXCLUDED.agent_id, ?)", r.agent_id),
            sweep_group_id: fragment("COALESCE(EXCLUDED.sweep_group_id, ?)", r.sweep_group_id),
            error_message: fragment("EXCLUDED.error_message")
          ]
        ]
      )
```

`open_ports` keeps replace semantics: a port that closed between batches must stop being open. `scanned_ports` unions: a port attempted in an earlier batch was still attempted.

- [ ] **Step 7: Run the unit tests and confirm they pass**

```bash
cd elixir/serviceradar_core && mix test test/serviceradar/sweep_jobs/sweep_results_ingestor_test.exs
```

Expected: PASS, including the four new tests and all pre-existing ones. The pre-existing `build_host_results/3` call sites must still compile via the default argument.

- [ ] **Step 8: Write the database-backed upsert test**

Create `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_host_result_coverage_db_test.exs`:

```elixir
defmodule ServiceRadar.SweepJobs.SweepHostResultCoverageDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  @moduletag :integration

  test "a second progress batch accumulates coverage and preserves identity" do
    %{execution_id: execution_id, group_id: group_id} = insert_execution()

    first = [
      %{
        "host" => "192.168.50.10",
        "available" => true,
        "port_results" => [%{"port" => 443, "available" => true}]
      }
    ]

    second = [
      %{
        "host" => "192.168.50.10",
        "available" => false,
        "port_results" => [%{"port" => 3001, "available" => false}]
      }
    ]

    ingest(first, execution_id, agent_id: "agent-a", sweep_group_id: group_id)
    ingest(second, execution_id, agent_id: nil, sweep_group_id: nil)

    row = fetch_row(execution_id, "192.168.50.10")

    assert Enum.sort(row.scanned_ports) == [443, 3001]
    assert row.open_ports == []
    assert row.agent_id == "agent-a"
    assert row.sweep_group_id == group_id
  end

  defp ingest(results, execution_id, context) do
    {records, _stats} =
      SweepResultsIngestor.build_host_results(results, execution_id, %{}, context)

    SweepResultsIngestor.bulk_insert_host_results(records)
  end

  defp fetch_row(execution_id, ip) do
    Repo.one!(
      from(r in ServiceRadar.SweepJobs.SweepHostResult,
        where: r.execution_id == ^execution_id and r.ip == ^ip
      )
    )
  end
end
```

If `bulk_insert_host_results/1` is private, make it public with a `@doc false` rather than reaching around it from the test; the test must exercise the real upsert query, because the merge semantics are the thing under test.

Add these helpers to the test module. The `Ash.create` shape matches
`sweep_results_flow_e2e_test.exs:72-84`:

```elixir
  defp insert_execution do
    actor = ServiceRadar.Support.SystemActor.system(:test)
    unique_id = System.unique_integer([:positive, :monotonic])

    {:ok, group} =
      ServiceRadar.SweepJobs.SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Coverage Group #{unique_id}", partition: "default", agent_ids: []},
        actor: actor
      )
      |> Ash.create()

    {:ok, execution} =
      ServiceRadar.SweepJobs.SweepGroupExecution
      |> Ash.Changeset.for_create(
        :create,
        %{sweep_group_id: group.id, status: :running, agent_id: "agent-a"},
        actor: actor
      )
      |> Ash.create()

    %{execution_id: execution.id, group_id: group.id}
  end
```

If `SweepGroupExecution` has no `:create` action accepting those fields, read
the resource and use the action it does expose. Do not add an action to the
production resource for the test's convenience.

- [ ] **Step 9: Register and run the database test**

Add to `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`:

```
test/serviceradar/sweep_jobs/sweep_host_result_coverage_db_test.exs	ServiceRadar.SweepJobs.SweepHostResultCoverageDbTest	data_case	serial	oban_global	Creates a SweepGroup whose default-enabled scheduling inserts global Oban workers via lib/serviceradar/sweep_jobs/changes/schedule_sweep_monitor.ex:27-30.
```

Run it through the guarded lifecycle from the `srql-fixtures-db-tests` skill. Mint one run id and use it for every invocation in the sequence; always invoke `teardown_db` even when the shard is red.

- [ ] **Step 10: Commit**

```bash
cd elixir/serviceradar_core && mix format
git add priv/repo/migrations/20260902120000_add_sweep_host_result_coverage.exs \
        lib/serviceradar/sweep_jobs/sweep_host_result.ex \
        lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex \
        test/serviceradar/sweep_jobs/sweep_results_ingestor_test.exs \
        test/serviceradar/sweep_jobs/sweep_host_result_coverage_db_test.exs \
        test/INTEGRATION_SOURCE_DISPOSITIONS.tsv
git commit -m "feat(sweep): persist scanned ports and result attribution"
```

---

## Task 3: Daily coverage rollup

**Files:**

- Create: `elixir/serviceradar_core/priv/repo/migrations/20260902130000_create_sweep_coverage_daily.exs`
- Create: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_coverage_rollup_worker.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_coverage_rollup_worker_db_test.exs`

**Interfaces:**

- Consumes: `sweep_host_results.scanned_ports`, `.agent_id`, `.sweep_group_id` from Task 2.
- Produces: `platform.sweep_coverage_daily`, unique on `(day, device_uid, ip, sweep_group_id, agent_id)`. Task 4 reads its watermark. Plan 2 exposes it as the `sweep_coverage` SRQL entity.
- Produces: `SweepCoverageRollupWorker.rollup_day(Date.t()) :: {:ok, non_neg_integer()}` returning rows written.

- [ ] **Step 1: Write the migration**

Create `elixir/serviceradar_core/priv/repo/migrations/20260902130000_create_sweep_coverage_daily.exs`:

```elixir
defmodule ServiceRadar.Repo.Migrations.CreateSweepCoverageDaily do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:sweep_coverage_daily, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :day, :date, null: false
      add :device_uid, :text
      add :ip, :text, null: false
      add :sweep_group_id, :uuid
      add :agent_id, :text
      add :execution_count, :bigint, null: false, default: 0
      add :available_count, :bigint, null: false, default: 0
      add :unavailable_count, :bigint, null: false, default: 0
      add :error_count, :bigint, null: false, default: 0
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :scanned_ports, {:array, :bigint}, null: false, default: []
      add :open_ports, {:array, :bigint}, null: false, default: []
      add :modes_requested, {:array, :text}, null: false, default: []
      add :modes_observed, {:array, :text}, null: false, default: []
      add :last_status, :text
      add :last_response_time_ms, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    # COALESCE in the key: a pre-Task-2 row has no group or agent, and NULLs
    # would defeat the unique index, letting every rerun insert duplicates.
    execute("""
    CREATE UNIQUE INDEX sweep_coverage_daily_grain_uidx
    ON #{@prefix}.sweep_coverage_daily (
      day,
      COALESCE(device_uid, ''),
      ip,
      COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(agent_id, '')
    )
    """)

    create index(:sweep_coverage_daily, [:device_uid, :day],
             prefix: @prefix,
             name: "sweep_coverage_daily_device_day_idx"
           )

    create index(:sweep_coverage_daily, [:sweep_group_id, :day],
             prefix: @prefix,
             name: "sweep_coverage_daily_group_day_idx"
           )
  end

  def down do
    drop_if_exists table(:sweep_coverage_daily, prefix: @prefix)
  end
end
```

- [ ] **Step 2: Write the failing worker test**

Create `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_coverage_rollup_worker_db_test.exs`. Cover exactly these behaviors:

```elixir
defmodule ServiceRadar.SweepJobs.SweepCoverageRollupWorkerDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepCoverageRollupWorker

  @moduletag :integration

  test "two sweep groups on one device and agent produce two rows" do
    day = Date.utc_today() |> Date.add(-1)
    device_uid = "device-overlap"
    {group_a, group_b} = {Ash.UUID.generate(), Ash.UUID.generate()}

    insert_result(day, device_uid, "10.0.0.5", group_a, "agent-a", [443], [443])
    insert_result(day, device_uid, "10.0.0.5", group_b, "agent-a", [3001], [])

    assert {:ok, 2} = SweepCoverageRollupWorker.rollup_day(day)

    rows = coverage_rows(day, device_uid)
    assert length(rows) == 2
    assert Enum.sort(Enum.map(rows, & &1.sweep_group_id)) == Enum.sort([group_a, group_b])
  end

  test "re-running a day does not double count" do
    day = Date.utc_today() |> Date.add(-1)
    device_uid = "device-idempotent"
    group = Ash.UUID.generate()

    insert_result(day, device_uid, "10.0.0.6", group, "agent-a", [443], [443])

    assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)
    [first] = coverage_rows(day, device_uid)

    assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)
    [second] = coverage_rows(day, device_uid)

    assert second.execution_count == first.execution_count
    assert second.available_count == first.available_count
    assert Enum.sort(second.scanned_ports) == Enum.sort(first.scanned_ports)
  end

  test "unions port coverage across executions in the day" do
    day = Date.utc_today() |> Date.add(-1)
    device_uid = "device-union"
    group = Ash.UUID.generate()

    insert_result(day, device_uid, "10.0.0.7", group, "agent-a", [443], [443])
    insert_result(day, device_uid, "10.0.0.7", group, "agent-a", [3001, 4502], [])

    assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)

    [row] = coverage_rows(day, device_uid)
    assert Enum.sort(row.scanned_ports) == [443, 3001, 4502]
    assert row.open_ports == [443]
    assert row.execution_count == 2
  end

  test "a day with no results writes nothing and still succeeds" do
    day = Date.utc_today() |> Date.add(-300)
    assert {:ok, 0} = SweepCoverageRollupWorker.rollup_day(day)
  end
end
```

Reuse the `insert_result_on/2` and `coverage_rows_on/1` helpers written in full in Task 4, Step 1, widened to take the group id, agent id, scanned ports and open ports as arguments. They insert a `sweep_group_executions` row plus a `sweep_host_results` row stamped at `day`, and count `platform.sweep_coverage_daily`. Do not invent a second fixture style.

- [ ] **Step 3: Run the test and read the failure**

Run through the guarded lifecycle. Expected: `SweepCoverageRollupWorker is not available`. Read the real text.

- [ ] **Step 4: Write the worker**

Create `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_coverage_rollup_worker.ex`.

The aggregation runs as one statement. Note the shape: scalar aggregates and port unions are computed in separate CTEs and joined. Do NOT try to union the arrays with `array_agg(scanned_ports)` in the scalar CTE: `array_agg` over `bigint[]` builds a multidimensional array and raises when rows have different array lengths, which is the normal case here.

```elixir
defmodule ServiceRadar.SweepJobs.SweepCoverageRollupWorker do
  @moduledoc """
  Rolls per-host sweep results into a daily per-device, per-group, per-agent
  summary that outlives the raw host result retention window.

  Raw results are kept for days; overlap and last-writer questions are asked
  for months. The grain is what makes overlap answerable: two rows sharing a
  day, device and agent but differing in sweep group is exactly the overlap
  case that `device_agent_availability` cannot represent, because it keeps
  only the last writer.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3600, fields: [:worker, :args]]

  alias ServiceRadar.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    day =
      case args["day"] do
        nil -> Date.add(Date.utc_today(), -1)
        value -> Date.from_iso8601!(value)
      end

    case rollup_day(day) do
      {:ok, count} ->
        Logger.info("SweepCoverageRollup: wrote #{count} row(s) for #{Date.to_iso8601(day)}")
        :ok

      {:error, reason} = error ->
        Logger.error("SweepCoverageRollup: failed for #{Date.to_iso8601(day)}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Aggregates one day of sweep host results into the coverage table.

  Idempotent: re-running a day replaces that day's rows rather than adding to
  them, so a retry or a manual re-run cannot double count.
  """
  @spec rollup_day(Date.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rollup_day(%Date{} = day) do
    case Repo.query(rollup_sql(), [day]) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollup_sql do
    """
    WITH src AS (
      SELECT
        r.execution_id,
        r.device_id AS device_uid,
        r.ip,
        COALESCE(r.sweep_group_id, e.sweep_group_id) AS sweep_group_id,
        COALESCE(r.agent_id, e.agent_id) AS agent_id,
        r.status,
        r.response_time_ms,
        r.scanned_ports,
        r.open_ports,
        r.sweep_modes_results,
        r.inserted_at
      FROM platform.sweep_host_results r
      JOIN platform.sweep_group_executions e ON e.id = r.execution_id
      WHERE r.inserted_at >= $1::date
        AND r.inserted_at < ($1::date + INTERVAL '1 day')
    ),
    scalars AS (
      SELECT
        device_uid, ip, sweep_group_id, agent_id,
        COUNT(DISTINCT execution_id) AS execution_count,
        COUNT(*) FILTER (WHERE status = 'available') AS available_count,
        COUNT(*) FILTER (WHERE status IN ('unavailable', 'timeout')) AS unavailable_count,
        COUNT(*) FILTER (WHERE status = 'error') AS error_count,
        MIN(inserted_at) AS first_seen_at,
        MAX(inserted_at) AS last_seen_at,
        (ARRAY_AGG(status ORDER BY inserted_at DESC))[1] AS last_status,
        (ARRAY_AGG(response_time_ms ORDER BY inserted_at DESC))[1] AS last_response_time_ms
      FROM src
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    ),
    scanned AS (
      SELECT device_uid, ip, sweep_group_id, agent_id,
             ARRAY_AGG(DISTINCT p ORDER BY p) AS ports
      FROM src, LATERAL unnest(src.scanned_ports) AS p
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    ),
    opened AS (
      SELECT device_uid, ip, sweep_group_id, agent_id,
             ARRAY_AGG(DISTINCT p ORDER BY p) AS ports
      FROM src, LATERAL unnest(src.open_ports) AS p
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    ),
    modes AS (
      SELECT device_uid, ip, sweep_group_id, agent_id,
             ARRAY_AGG(DISTINCT m.key ORDER BY m.key) AS requested,
             ARRAY_AGG(DISTINCT m.key ORDER BY m.key)
               FILTER (WHERE m.value::text NOT IN ('null', '"unknown"')) AS observed
      FROM src, LATERAL jsonb_each(src.sweep_modes_results) AS m(key, value)
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    )
    INSERT INTO platform.sweep_coverage_daily AS t (
      id, day, device_uid, ip, sweep_group_id, agent_id,
      execution_count, available_count, unavailable_count, error_count,
      first_seen_at, last_seen_at,
      scanned_ports, open_ports, modes_requested, modes_observed,
      last_status, last_response_time_ms, inserted_at, updated_at
    )
    SELECT
      gen_random_uuid(), $1::date, s.device_uid, s.ip, s.sweep_group_id, s.agent_id,
      s.execution_count, s.available_count, s.unavailable_count, s.error_count,
      s.first_seen_at, s.last_seen_at,
      COALESCE(sc.ports, '{}'::bigint[]),
      COALESCE(op.ports, '{}'::bigint[]),
      COALESCE(md.requested, '{}'::text[]),
      COALESCE(md.observed, '{}'::text[]),
      s.last_status, s.last_response_time_ms,
      now(), now()
    FROM scalars s
    LEFT JOIN scanned sc USING (device_uid, ip, sweep_group_id, agent_id)
    LEFT JOIN opened op USING (device_uid, ip, sweep_group_id, agent_id)
    LEFT JOIN modes md USING (device_uid, ip, sweep_group_id, agent_id)
    ON CONFLICT (
      day,
      COALESCE(device_uid, ''),
      ip,
      COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(agent_id, '')
    )
    DO UPDATE SET
      execution_count = EXCLUDED.execution_count,
      available_count = EXCLUDED.available_count,
      unavailable_count = EXCLUDED.unavailable_count,
      error_count = EXCLUDED.error_count,
      first_seen_at = LEAST(t.first_seen_at, EXCLUDED.first_seen_at),
      last_seen_at = GREATEST(t.last_seen_at, EXCLUDED.last_seen_at),
      scanned_ports = EXCLUDED.scanned_ports,
      open_ports = EXCLUDED.open_ports,
      modes_requested = EXCLUDED.modes_requested,
      modes_observed = EXCLUDED.modes_observed,
      last_status = EXCLUDED.last_status,
      last_response_time_ms = EXCLUDED.last_response_time_ms,
      updated_at = now()
    """
  end
end
```

The `DO UPDATE` assigns rather than accumulates. That is what makes a re-run idempotent: the recomputed value for the day replaces the previous one, so running twice equals running once.

- [ ] **Step 5: Run the tests and confirm they pass**

Run through the guarded lifecycle with `--nocache_test_results`. Expected: PASS, 4 tests.

- [ ] **Step 6: Mutation-check idempotency**

Temporarily change `execution_count = EXCLUDED.execution_count` to `execution_count = t.execution_count + EXCLUDED.execution_count`. The idempotency test MUST fail. Revert. If it stays green, the test is not exercising the second run.

- [ ] **Step 7: Register and commit**

Add to `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`:

```
test/serviceradar/sweep_jobs/sweep_coverage_rollup_worker_db_test.exs	ServiceRadar.SweepJobs.SweepCoverageRollupWorkerDbTest	data_case	serial	ddl	Inserts into and aggregates over platform.sweep_coverage_daily; the shared rollup table cannot overlap with another test writing the same day grain.
```

```bash
cd elixir/serviceradar_core && mix format
git add priv/repo/migrations/20260902130000_create_sweep_coverage_daily.exs \
        lib/serviceradar/sweep_jobs/sweep_coverage_rollup_worker.ex \
        test/serviceradar/sweep_jobs/sweep_coverage_rollup_worker_db_test.exs \
        test/INTEGRATION_SOURCE_DISPOSITIONS.tsv
git commit -m "feat(sweep): roll daily sweep coverage into a durable summary"
```

---

## Task 4: Rollup-aware cleanup and retention

The cleanup worker currently deletes host results older than 7 days on a timer. Once the rollup exists, deleting a day that has not been rolled up destroys history permanently. Scheduling the rollup earlier is not a guarantee; a failed or skipped rollup run must block the delete.

**Files:**

- Modify: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_data_cleanup_worker.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_data_cleanup_watermark_db_test.exs`

**Interfaces:**

- Consumes: `platform.sweep_coverage_daily` from Task 3.
- Produces: no new public function. The worker's only public entry points stay `ensure_scheduled/0` and the `perform/1` Oban callback. Retention is read from `Application.get_env(:serviceradar_core, SweepDataCleanupWorker, [])`, and a new `:rollup_retention_days` key joins the existing `:host_results_retention_days`, `:executions_retention_days` and `:batch_size`.

Two things about this worker to know before you touch it. It has no test file of its own, so nothing existing protects you. And `perform/1` returns a bare `:ok` and reschedules itself through `ObanSupport.safe_insert/1`, so the test must assert on database state rather than a returned stats map, and must tolerate the follow-up job insert.

- [ ] **Step 1: Write the failing watermark test**

Create `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_data_cleanup_watermark_db_test.exs`:

```elixir
defmodule ServiceRadar.SweepJobs.SweepDataCleanupWatermarkDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepCoverageRollupWorker
  alias ServiceRadar.SweepJobs.SweepDataCleanupWorker
  alias ServiceRadar.SweepJobs.SweepHostResult

  @moduletag :integration

  setup do
    previous = Application.get_env(:serviceradar_core, SweepDataCleanupWorker, [])

    Application.put_env(:serviceradar_core, SweepDataCleanupWorker,
      host_results_retention_days: 7,
      executions_retention_days: 30,
      rollup_retention_days: 400,
      batch_size: 100
    )

    on_exit(fn ->
      Application.put_env(:serviceradar_core, SweepDataCleanupWorker, previous)
    end)

    :ok
  end

  test "a day that has not been rolled up is not deleted" do
    day = Date.add(Date.utc_today(), -10)
    insert_result_on(day, "10.0.1.5")

    assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})

    assert host_results_on(day) == 1
  end

  test "a rolled-up day past retention is deleted, and its coverage survives" do
    day = Date.add(Date.utc_today(), -10)
    insert_result_on(day, "10.0.1.6")

    {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)

    assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})

    assert host_results_on(day) == 0
    assert coverage_rows_on(day) == 1
  end

  test "coverage rows past the rollup retention are deleted" do
    day = Date.add(Date.utc_today(), -500)
    insert_result_on(day, "10.0.1.7")
    {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)

    assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})

    assert coverage_rows_on(day) == 0
  end

  defp insert_result_on(day, ip) do
    actor = ServiceRadar.Support.SystemActor.system(:test)
    unique_id = System.unique_integer([:positive, :monotonic])
    at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

    {:ok, group} =
      ServiceRadar.SweepJobs.SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Watermark Group #{unique_id}", partition: "default", agent_ids: []},
        actor: actor
      )
      |> Ash.create()

    {:ok, execution} =
      ServiceRadar.SweepJobs.SweepGroupExecution
      |> Ash.Changeset.for_create(
        :create,
        %{sweep_group_id: group.id, status: :completed, agent_id: "agent-a"},
        actor: actor
      )
      |> Ash.create()

    Repo.insert_all(SweepHostResult, [
      %{
        id: Ash.UUID.generate(),
        execution_id: execution.id,
        ip: ip,
        status: :available,
        open_ports: [443],
        scanned_ports: [443, 3001],
        sweep_modes_results: %{"tcp" => "success"},
        agent_id: "agent-a",
        sweep_group_id: group.id,
        inserted_at: at
      }
    ])

    :ok
  end

  defp host_results_on(day) do
    from_at = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")
    to_at = DateTime.new!(Date.add(day, 1), ~T[00:00:00.000000], "Etc/UTC")

    Repo.one!(
      from(r in SweepHostResult,
        where: r.inserted_at >= ^from_at and r.inserted_at < ^to_at,
        select: count(r.id)
      )
    )
  end

  defp coverage_rows_on(day) do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM platform.sweep_coverage_daily WHERE day = $1", [day])

    count
  end
end
```

- [ ] **Step 2: Run the test and read the failure**

Run through the guarded lifecycle. Expected: test 1 fails because cleanup deletes the unrolled day, and test 3 fails because nothing deletes coverage rows.

Confirm test 1 actually fails before you change anything. If it passes on an unmodified worker, the fixture is not writing a row old enough to be eligible and the test is proving nothing.

- [ ] **Step 3: Add the watermark guard and rollup retention**

In `sweep_data_cleanup_worker.ex`, add the default beside the existing ones:

```elixir
  @default_rollup_retention_days 400
```

Add the watermark helpers:

```elixir
  # The last day fully covered by the rollup. Host results may only be deleted
  # up to this point, because deleting an unrolled day destroys the only
  # durable record of which sweep group and agent produced those results.
  defp rollup_watermark do
    case Repo.query("SELECT MAX(day) FROM platform.sweep_coverage_daily", []) do
      {:ok, %{rows: [[%Date{} = day]]}} ->
        DateTime.new!(Date.add(day, 1), ~T[00:00:00.000000], "Etc/UTC")

      _ ->
        nil
    end
  end
```

In `perform/1`, clamp the host-results cutoff and add the coverage cutoff:

```elixir
    rollup_days = Keyword.get(config, :rollup_retention_days, @default_rollup_retention_days)

    host_results_cutoff =
      case rollup_watermark() do
        # Nothing has ever been rolled up. Skip the host-result delete entirely
        # rather than falling back to the unguarded cutoff: an empty rollup
        # table is precisely when deleting is most destructive.
        nil ->
          nil

        watermark ->
          Enum.min([DateTime.add(DateTime.utc_now(), -host_results_days * 86_400, :second), watermark], DateTime)
      end

    coverage_cutoff = Date.add(Date.utc_today(), -rollup_days)
```

Make `cleanup_host_results/2` a no-op returning `%{deleted: 0, errors: 0}` when the cutoff is `nil`, and log that the delete was skipped and why. A silent skip here is indistinguishable from a working delete.

Add a coverage delete using the same batched approach, keyed on the `day` column, and include `coverage_rollups` in the stats map returned by `cleanup_data/3` and in the completion log line.

- [ ] **Step 4: Run the tests and confirm they pass**

Run through the guarded lifecycle with `--nocache_test_results`. Expected: PASS, 3 tests.

- [ ] **Step 5: Mutation-check the guard**

Temporarily make the `nil` watermark branch fall through to the unguarded cutoff. Test 1 MUST fail. Revert.

- [ ] **Step 6: Schedule the rollup ahead of cleanup**

`SweepDataCleanupWorker.ensure_scheduled/0` is the pattern to copy. Give `SweepCoverageRollupWorker` the same treatment on a daily cadence, earlier in the day, and call it wherever `ensure_scheduled/0` is called today.

The watermark guard is the correctness mechanism; ordering is only an optimization so the guard rarely has to block a delete. Do not rely on ordering alone.

- [ ] **Step 7: Register and commit**

Add to `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`:

```
test/serviceradar/sweep_jobs/sweep_data_cleanup_watermark_db_test.exs	ServiceRadar.SweepJobs.SweepDataCleanupWatermarkDbTest	data_case	serial	oban_global	Invokes SweepDataCleanupWorker.perform/1, which deletes from shared sweep tables and self-reschedules a global Oban job via lib/serviceradar/sweep_jobs/sweep_data_cleanup_worker.ex:117-121.
```

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/sweep_jobs/sweep_data_cleanup_worker.ex \
        test/serviceradar/sweep_jobs/sweep_data_cleanup_watermark_db_test.exs \
        test/INTEGRATION_SOURCE_DISPOSITIONS.tsv
git commit -m "feat(sweep): block cleanup of days that have not been rolled up"
```

---

## Task 5: Full verification

- [ ] **Step 1: Update the OpenSpec checklist**

Tick tasks 1.1 through 2.5 in `openspec/changes/add-sweep-diagnostics-srql-entities/tasks.md`. Leave sections 3 through 6 unticked; plan 2 owns them.

- [ ] **Step 2: Run the whole suite the way CI does**

```bash
make test
```

Expected: green. This is the only command that covers the Elixir unit shards, which exist solely as Bazel targets and are invisible to `mix test`.

- [ ] **Step 3: Confirm the migration applies and reverses**

Against a scratch database from the `srql-fixtures-db-tests` skill, run the migration up, then down, then up again. A migration that cannot roll back is a migration you cannot deploy safely.

- [ ] **Step 4: Commit and open the PR**

```bash
git push origin feat/4167-sweep-diagnostics-srql-mcp:refs/heads/feat/4167-sweep-diagnostics-srql-mcp
```

Verify the push line says `-> feat/4167-sweep-diagnostics-srql-mcp` and never `-> staging`. Open the PR with `gh --repo carverauto/serviceradar`, referencing issue #4167 and noting that it ships the collection half only.
