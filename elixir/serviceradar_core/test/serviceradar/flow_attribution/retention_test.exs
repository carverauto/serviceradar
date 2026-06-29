defmodule ServiceRadar.FlowAttribution.RetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.FlowAttribution.Retention

  # Must match @batch_size in Retention: the loop treats a batch >= this as "maybe more".
  @batch_size 50_000

  # A deleter that returns each queued result in turn (and {:ok, 0} once exhausted),
  # standing in for delete_batch/0 so the batching loop is testable without a DB.
  defp seq_deleter(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn ->
      Agent.get_and_update(agent, fn
        [head | tail] -> {head, tail}
        [] -> {{:ok, 0}, []}
      end)
    end
  end

  test "drains the backlog across batches and sums the deleted counts" do
    deleter = seq_deleter([{:ok, @batch_size}, {:ok, @batch_size}, {:ok, 30_000}])
    assert {:ok, 130_000} = Retention.prune(deleter: deleter)
  end

  test "stops after a single short/empty batch when nothing (or little) is expired" do
    assert {:ok, 0} = Retention.prune(deleter: seq_deleter([{:ok, 0}]))
    assert {:ok, 42} = Retention.prune(deleter: seq_deleter([{:ok, 42}]))
  end

  test "caps work per pass at max_batches so one pass can't run unbounded" do
    deleter = seq_deleter(List.duplicate({:ok, @batch_size}, 10))
    assert {:ok, 100_000} = Retention.prune(deleter: deleter, max_batches: 2)
  end

  test "surfaces the error when the very first batch fails" do
    assert {:error, :boom} = Retention.prune(deleter: seq_deleter([{:error, :boom}]))
  end

  test "reports partial success when a later batch fails (next pass resumes draining)" do
    deleter = seq_deleter([{:ok, @batch_size}, {:error, :boom}])
    assert {:ok, @batch_size} = Retention.prune(deleter: deleter)
  end
end
