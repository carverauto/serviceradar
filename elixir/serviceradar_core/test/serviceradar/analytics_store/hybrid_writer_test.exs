defmodule ServiceRadar.AnalyticsStore.HybridWriterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.HybridWriter

  defmodule TransactionRepo do
    def transaction(fun) do
      send(self(), :transaction_started)
      result = fun.()
      send(self(), :transaction_committed)
      {:ok, result}
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def rollback(reason), do: throw({:rollback, reason})

    def insert_all(table, rows, opts) do
      send(self(), {:insert, table, rows, opts})
      {1, [%{timestamp: ~U[2034-01-02 12:00:00Z], value: 42.0}]}
    end
  end

  test "enqueues only canonical returned rows in the hot insert transaction" do
    input = [%{value: 1.0}, %{value: 2.0}]

    assert {:ok, 1} =
             HybridWriter.write("timeseries_metrics", input,
               repo: TransactionRepo,
               transaction: &TransactionRepo.transaction/1,
               returning: false,
               on_conflict: :replace_all,
               enqueue_rows: fn "timeseries_metrics", [%{value: 42.0}], _ ->
                 assert_received :transaction_started
                 refute_received :transaction_committed
                 {:ok, 1}
               end
             )

    assert_received {:insert, "timeseries_metrics", ^input, opts}
    assert opts[:on_conflict] == :nothing
    assert :timestamp in opts[:returning]
    assert :gateway_id in opts[:returning]
    assert :series_key in opts[:returning]
    assert_received :transaction_committed
  end

  test "durable archive handoff failure rolls back the hot insert" do
    assert {:error, :archive_buffer_full} =
             HybridWriter.write("timeseries_metrics", [%{value: 1.0}],
               repo: TransactionRepo,
               transaction: &TransactionRepo.transaction/1,
               enqueue_rows: fn _, _, _ -> {:error, :archive_buffer_full} end
             )

    refute_received :transaction_committed
  end

  test "empty input does no database or archive work and unsupported tables fail closed" do
    assert {:ok, 0} = HybridWriter.write("timeseries_metrics", [], repo: TransactionRepo)
    refute_received :transaction_started
    assert {:error, {:unsupported_hybrid_table, "logs"}} = HybridWriter.write("logs", [])
  end
end
