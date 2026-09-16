defmodule ServiceRadarWebNG.SRQLPlanCacheModeTest do
  @moduledoc """
  Regression tests for the SRQL query-plan strategy.

  SRQL SQL is executed by Postgrex as *named prepared statements* (see
  `ServiceRadarWebNG.SRQL.run_sql/2`). After ~5 executions PostgreSQL caches a
  *generic* plan that cannot estimate the selectivity of parameterized
  `= ANY($n)` filters, which made the Observability log severity drill-down scan
  a timestamp index + filter instead of the selective severity index and
  statement-time-out. `run_sql/2` therefore issues `session_setup_sql/0`, which
  sets `plan_cache_mode = force_custom_plan` transaction-locally before every
  SRQL query so the planner re-estimates per execution and picks the right index.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.SRQL

  describe "session_setup_sql/0" do
    @tag :db_free
    test "forces a custom query plan transaction-locally" do
      sql = SRQL.session_setup_sql()

      # plan_cache_mode must be forced to a custom plan...
      assert sql =~ "plan_cache_mode"
      assert sql =~ "force_custom_plan"

      # ...and the statement timeout must still be applied.
      assert sql =~ "statement_timeout"

      # ...all via the SET LOCAL / transaction-local form of set_config
      # (is_local = true), so the settings never leak to unrelated queries on
      # the pooled connection. A `false` is_local here would be a leak.
      refute sql =~ ~r/set_config\([^)]*,\s*false\)/
      assert sql =~ ~r/set_config\('plan_cache_mode',\s*'force_custom_plan',\s*true\)/
      assert sql =~ ~r/set_config\('jit',\s*'off',\s*true\)/
    end
  end

  describe "caller query deadline" do
    @tag :db_free
    test "a batch shares one configured deadline that callers can only shorten" do
      now = 1_000
      assert {:ok, postgres_budget} = SRQL.query_timeout_ms(%{}, %{}, now)
      assert {:ok, duckdb_budget} = SRQL.query_timeout_ms(%{"dialect" => "duckdb"}, %{}, now)
      budget = min(postgres_budget, duckdb_budget)
      deadline = now + budget
      shorter = max(div(budget, 2), 1)

      assert SRQL.batch_execution_opts(%{}, now) == %{deadline: deadline}
      assert SRQL.batch_execution_opts(%{timeout: shorter}, now) == %{deadline: now + shorter}

      assert SRQL.batch_execution_opts(%{deadline: now + shorter, timeout: budget}, now) ==
               %{deadline: now + shorter}

      assert SRQL.batch_execution_opts(%{deadline: deadline + budget, timeout: budget * 3}, now) ==
               %{deadline: deadline}

      assert SRQL.query_timeout_ms(%{}, SRQL.batch_execution_opts(%{}, now), deadline) == {:error, :timeout}
    end

    @tag :db_free
    test "shortens both backends and never extends configured budgets" do
      for translation <- [%{}, %{"dialect" => "duckdb"}] do
        assert SRQL.query_timeout_ms(translation, %{deadline: 1_125}, 1_000) == {:ok, 125}
        assert SRQL.query_timeout_ms(translation, %{deadline: 1_000}, 1_000) == {:error, :timeout}
        assert SRQL.query_timeout_ms(translation, %{deadline: 999}, 1_000) == {:error, :timeout}
        configured = SRQL.query_timeout_ms(translation, %{}, 0)
        assert SRQL.query_timeout_ms(translation, %{deadline: 1_000_000}, 0) == configured
      end
    end

    @tag :db_free
    test "query propagates an expired internal deadline without opening a database connection" do
      scope = %ServiceRadarWebNG.Accounts.Scope{permissions: MapSet.new(["observability.metrics.view"])}
      query = ~s(in:timeseries_metrics uid:"synthetic-deadline-device" time:last_1h bucket:5m agg:avg limit:10)
      assert SRQL.query(query, %{scope: scope, deadline: System.monotonic_time(:millisecond) - 1}) == {:error, :timeout}
    end
  end

  describe "session_setup_sql/0 applied against the database" do
    setup do
      :ok = Sandbox.checkout(Repo)
      Sandbox.mode(Repo, {:shared, self()})
      :ok
    end

    test "sets plan_cache_mode = force_custom_plan for the current transaction" do
      # Run the setup statement exactly as run_sql/2 does, then observe the GUC
      # on the same connection/transaction.
      assert {:ok, _} = SQL.query(Repo, SRQL.session_setup_sql(), ["5s"])

      assert %{rows: [["force_custom_plan"]]} =
               SQL.query!(Repo, "SELECT current_setting('plan_cache_mode')", [])

      # The statement timeout was applied in the same call.
      assert %{rows: [["5s"]]} =
               SQL.query!(Repo, "SELECT current_setting('statement_timeout')", [])

      assert %{rows: [["off"]]} = SQL.query!(Repo, "SELECT current_setting('jit')", [])
    end

    test "restores the pooled connection's JIT setting after commit and rollback" do
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[original]]} = SQL.query!(Repo, "SELECT current_setting('jit')", [])

        try do
          SQL.query!(Repo, "SELECT set_config('jit', 'on', false)", [])

          for outcome <- [:commit, :rollback] do
            result =
              Repo.transaction(fn ->
                SQL.query!(Repo, SRQL.session_setup_sql(), ["5s"])
                assert %{rows: [["off"]]} = SQL.query!(Repo, "SELECT current_setting('jit')", [])

                if outcome == :rollback, do: Repo.rollback(:expected), else: :ok
              end)

            assert result == if(outcome == :commit, do: {:ok, :ok}, else: {:error, :expected})
            assert %{rows: [["on"]]} = SQL.query!(Repo, "SELECT current_setting('jit')", [])
          end
        after
          SQL.query!(Repo, "SELECT set_config('jit', $1, false)", [original])
        end
      end)
    end
  end
end
