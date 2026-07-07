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

      # ...both via the SET LOCAL / transaction-local form of set_config
      # (is_local = true), so the settings never leak to unrelated queries on
      # the pooled connection. A `false` is_local here would be a leak.
      refute sql =~ ~r/set_config\([^)]*,\s*false\)/
      assert sql =~ ~r/set_config\('plan_cache_mode',\s*'force_custom_plan',\s*true\)/
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
    end
  end
end
