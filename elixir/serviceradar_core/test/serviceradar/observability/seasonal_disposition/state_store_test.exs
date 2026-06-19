defmodule ServiceRadar.Observability.SeasonalDisposition.StateStoreTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Observability.SeasonalDisposition.StateStore

  @source %Source{name: "cpu_seasonal"}
  @now ~U[2026-06-19 12:00:00.000000Z]

  defmodule FakeRepo do
    @moduledoc false

    def query("SELECT " <> _ = sql, params) do
      send(Process.get(:test_pid), {:query, sql, params})
      {:ok, %{rows: [["svc/cpu/a", 0, 3, 2]]}}
    end

    def query("DELETE " <> _ = sql, params) do
      send(Process.get(:test_pid), {:cleanup, sql, params})
      {:ok, %{num_rows: 1}}
    end

    def insert_all(table, rows, opts) do
      send(Process.get(:test_pid), {:insert_all, table, rows, opts})
      {length(rows), nil}
    end
  end

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  test "loads existing counters in one batched query" do
    assert {:ok, states} =
             StateStore.load_many(
               @source,
               [{"svc/cpu/a", 0, 3}, {"svc/cpu/b", 1, 4}],
               repo: FakeRepo
             )

    assert states == %{{"svc/cpu/a", 0, 3} => 2}

    assert_received {:query, sql, ["cpu_seasonal", ["svc/cpu/a", "svc/cpu/b"], [0, 1], [3, 4]]}
    assert sql =~ "FROM platform.seasonal_disposition_states"
    assert sql =~ "unnest($2::text[], $3::int[], $4::int[])"
    assert sql =~ "expires_at > now()"
  end

  test "upserts next counters with ttl without cleanup in the write path" do
    assert :ok =
             StateStore.persist_many(
               @source,
               [
                 %{
                   key: {"svc/cpu/a", 0, 3},
                   consecutive_anomalous: 3,
                   bucket_started_at: ~U[2026-06-19 03:00:00Z],
                   bucket_ended_at: ~U[2026-06-19 04:00:00Z]
                 }
               ],
               repo: FakeRepo,
               now: @now,
               seasonal_state_ttl_days: 7
             )

    assert_received {:insert_all, "seasonal_disposition_states", [row], opts}
    assert row.source == "cpu_seasonal"
    assert row.series_key == "svc/cpu/a"
    assert row.dow == 0
    assert row.hod == 3
    assert row.consecutive_anomalous == 3
    assert row.expires_at == ~U[2026-06-26 12:00:00.000000Z]
    assert opts[:prefix] == "platform"
    assert opts[:conflict_target] == [:source, :series_key, :dow, :hod]
    assert {:replace, fields} = opts[:on_conflict]
    assert :expires_at in fields
    assert :updated_at in fields
    refute_received {:cleanup, _cleanup_sql, []}
  end
end
