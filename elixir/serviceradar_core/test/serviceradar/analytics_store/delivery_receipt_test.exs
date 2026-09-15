defmodule ServiceRadar.AnalyticsStore.DeliveryReceiptTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.DeliveryReceipt
  alias ServiceRadar.EventWriter.JetStreamAck
  alias ServiceRadar.EventWriter.Processors.Metrics

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
  end

  test "identity survives consumer and delivery changes but includes source and original timestamp" do
    first = message("$JS.ACK.example.account.metrics.reader.1.12.3.123456789.0")
    replay = message("$JS.ACK.example.account.metrics.other-reader.4.12.90.123456789.0")
    assert DeliveryReceipt.identity(first) == DeliveryReceipt.identity(replay)

    for reply <- [
          "$JS.ACK.other.account.metrics.reader.1.12.3.123456789.0",
          "$JS.ACK.example.account.metrics.reader.1.13.3.123456789.0",
          "$JS.ACK.example.account.metrics.reader.1.12.3.987654321.0"
        ] do
      refute DeliveryReceipt.identity(first) == DeliveryReceipt.identity(message(reply))
    end
  end

  test "missing or malformed source identities fail closed" do
    for input <- [
          %{},
          %{metadata: %{}},
          message("invalid"),
          message("$JS.ACK.metrics.reader.1.0.3.0.0")
        ] do
      assert DeliveryReceipt.identity(input) == {:error, :missing_jetstream_identity}
    end
  end

  test "only newly claimed messages reach the processor before commit" do
    old = message("$JS.ACK.metrics.reader.1.11.1.123456789.0")
    fresh = message("$JS.ACK.metrics.reader.1.12.2.123456790.0")

    assert {:ok, 1} =
             DeliveryReceipt.process_batch(Metrics, [old, fresh],
               config: hybrid(),
               repo: TransactionRepo,
               transaction: &TransactionRepo.transaction/1,
               claim_fn: fn [^old, ^fresh], _opts ->
                 assert_received :transaction_started
                 {:ok, [fresh]}
               end,
               processor_fn: fn [^fresh] ->
                 refute_received :transaction_committed
                 {:ok, 1}
               end
             )

    assert_received :transaction_committed
  end

  test "fully replayed batches commit without decoding or writing again" do
    assert {:ok, 0} =
             DeliveryReceipt.process_batch(Metrics, [],
               config: hybrid(),
               repo: TransactionRepo,
               transaction: &TransactionRepo.transaction/1,
               claim_fn: fn _, _ -> {:ok, []} end,
               processor_fn: fn _ -> flunk("replayed deliveries reached the processor") end
             )
  end

  test "processor failure rolls back receipt admission" do
    assert {:error, :archive_buffer_full} =
             DeliveryReceipt.process_batch(Metrics, [%{}],
               config: hybrid(),
               repo: TransactionRepo,
               transaction: &TransactionRepo.transaction/1,
               claim_fn: fn messages, _ -> {:ok, messages} end,
               processor_fn: fn _ -> {:error, :archive_buffer_full} end
             )

    refute_received :transaction_committed
  end

  test "auxiliary facts run after commit and cannot fail an accepted delivery" do
    for callback <- [
          fn -> send(self(), :facts_written) end,
          fn -> raise "synthetic fact failure" end,
          fn -> exit(:synthetic_fact_exit) end
        ] do
      assert {:ok, 1} =
               DeliveryReceipt.process_batch(Metrics, [%{}],
                 config: hybrid(),
                 repo: TransactionRepo,
                 transaction: &TransactionRepo.transaction/1,
                 claim_fn: fn messages, _ -> {:ok, messages} end,
                 processor_fn: fn _ ->
                   {:ok, 1,
                    fn ->
                      committed? =
                        receive do
                          :transaction_committed -> true
                        after
                          0 -> false
                        end

                      send(self(), {:facts_after_commit, committed?})
                      callback.()
                    end}
                 end
               )

      assert_received {:facts_after_commit, true}
    end

    assert_received :facts_written
  end

  test "legacy modes bypass receipt admission" do
    for driver <- [:timescale, :pg_duckdb] do
      assert {:ok, 1} =
               DeliveryReceipt.process_batch(Metrics, [%{}],
                 config: Config.load(driver: driver, tables: "timeseries_metrics"),
                 repo: TransactionRepo,
                 transaction: &TransactionRepo.transaction/1,
                 claim_fn: fn _, _ -> flunk("legacy mode claimed a receipt") end,
                 processor_fn: fn [%{}] -> {:ok, 1} end
               )
    end

    refute_received :transaction_started
  end

  defp message(reply), do: %{metadata: %{jetstream_ack: JetStreamAck.parse(reply)}}
  defp hybrid, do: Config.load(driver: :hybrid, tables: "timeseries_metrics")
end
