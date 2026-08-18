defmodule ServiceRadar.Notifications.DeliveryRetentionWorkerTest do
  @moduledoc """
  The delivery pruner's window, its predicate, and its batching.

  The predicate is the part worth pinning. Two rows must never be deleted:

  1. Anything still `:pending` or `:dispatching`. Retry keeps a delivery
     `:pending` (design D4 - only `:failed` is terminal), so a `:pending` row is
     a page that is still owed, and deleting it silently cancels it.
  2. A suppression row that is still collapsing repeats onto itself.
     `:record_suppression` refreshes `last_evaluated_at` on every repeat while
     `inserted_at` stays put, so pruning on `inserted_at` alone would delete an
     actively-written row mid-silence and immediately recreate it, resetting the
     `occurrence_count` an operator is reading.

  The window itself is the other property: it is deliberately **not**
  `AlertsRetentionWorker`'s three days. A delivery outlives the alert it points
  at - that is why `alert_snapshot` is required and why `alert_id` is
  `nilify_all` - so sharing the alerts window would delete the audit trail three
  days in and make the snapshot pointless machinery.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.DeliveryRetentionWorker

  @now ~U[2026-08-09 12:00:00.000000Z]

  defp job, do: %Oban.Job{args: %{}}

  # Records each batch and replays a scripted row count, so the batching, the
  # cap, and the parameters can be asserted without a database.
  defp query(counts) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> counts end)

    fn sql, params ->
      send(test, {:query, sql, params})

      agent
      |> Agent.get_and_update(fn
        [head | tail] -> {head, tail}
        [] -> {0, []}
      end)
      |> then(&{:ok, %{num_rows: &1}})
    end
  end

  describe "the retention window" do
    test "defaults to a window of its own, longer than the alerts window" do
      %{retention_days: days} = DeliveryRetentionWorker.config()

      # AlertsRetentionWorker's default is 3 days. A delivery outlives its alert.
      assert days > 3
    end

    test "the cutoff is retention_days before the given instant" do
      assert DeliveryRetentionWorker.cutoff(@now, 30) == ~U[2026-07-10 12:00:00.000000Z]
    end

    test "the cutoff is derived from the injected instant, not the wall clock" do
      assert :ok = DeliveryRetentionWorker.prune(job(), now: @now, query: query([0]))

      %{retention_days: days} = DeliveryRetentionWorker.config()
      expected = DeliveryRetentionWorker.cutoff(@now, days)

      assert_received {:query, _sql, [^expected, _states, _limit]}
    end
  end

  describe "the predicate" do
    test "only settled states are prunable" do
      assert DeliveryRetentionWorker.settled_states() == ~w(
               sent
               failed
               expired
               cancelled
               suppressed
               skipped
             )
    end

    test "an owed delivery is never in the prunable set" do
      # :pending is where a retry-eligible delivery waits and :dispatching is a
      # row an attempt is holding. Deleting either cancels a page.
      refute "pending" in DeliveryRetentionWorker.settled_states()
      refute "dispatching" in DeliveryRetentionWorker.settled_states()
    end

    test "the delete is bounded by state, by inserted_at, and by last_evaluated_at" do
      sql = DeliveryRetentionWorker.delete_batch_sql()

      assert sql =~ "state = ANY($2)"
      assert sql =~ "inserted_at < $1"
      # Spares a suppression row that repeats are still collapsing onto.
      assert sql =~ "last_evaluated_at IS NULL OR last_evaluated_at < $1"
    end

    test "the delete is ctid-addressed and row-limited" do
      sql = DeliveryRetentionWorker.delete_batch_sql()

      assert sql =~ "WHERE ctid IN ("
      assert sql =~ "LIMIT $3"
    end

    test "the settled states are passed as a parameter, not interpolated" do
      assert :ok = DeliveryRetentionWorker.prune(job(), now: @now, query: query([0]))

      assert_received {:query, _sql, [_cutoff, states, _limit]}
      assert states == DeliveryRetentionWorker.settled_states()
    end
  end

  describe "batching" do
    test "a short batch ends the pass" do
      assert :ok = DeliveryRetentionWorker.prune(job(), now: @now, query: query([3]))

      assert_received {:query, _sql, _params}
      refute_received {:query, _sql, _params}
    end

    test "a full batch is followed by another" do
      %{batch_size: batch_size} = DeliveryRetentionWorker.config()

      assert :ok =
               DeliveryRetentionWorker.prune(job(),
                 now: @now,
                 query: query([batch_size, batch_size, 1])
               )

      assert_received {:query, _sql, _params}
      assert_received {:query, _sql, _params}
      assert_received {:query, _sql, _params}
      refute_received {:query, _sql, _params}
    end

    test "the batch cap defers the remainder instead of running unbounded" do
      %{batch_size: batch_size, max_batches: max_batches} = DeliveryRetentionWorker.config()

      full_batches = List.duplicate(batch_size, max_batches + 5)

      assert :ok = DeliveryRetentionWorker.prune(job(), now: @now, query: query(full_batches))

      # Whatever the cap defers is still there tomorrow; an unbounded delete on a
      # table this size is what took the flow-attribution prune out (#4329).
      assert length(collect_queries()) == max_batches
    end
  end

  describe "failure handling" do
    test "a missing table is a not-yet, not a failure" do
      # The notification tables are created by an Elixir migration; a deployment
      # that has not migrated must not retry three times and page anybody.
      missing = fn _sql, _params ->
        {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}}
      end

      assert :ok = DeliveryRetentionWorker.prune(job(), now: @now, query: missing)
    end

    test "a real query failure is returned so Oban retries the pass" do
      failing = fn _sql, _params -> {:error, :connection_closed} end

      assert {:error, :connection_closed} =
               DeliveryRetentionWorker.prune(job(), now: @now, query: failing)
    end
  end

  describe "oban options" do
    test "the pass runs on maintenance, not on the notifications queue" do
      changes = DeliveryRetentionWorker.new(%{}).changes

      # A daily bulk delete that can run for minutes must not hold one of the
      # five notification slots the delivery worker shares.
      assert changes.queue == "maintenance"
      assert %{period: :infinity} = changes.unique
    end
  end

  defp collect_queries(acc \\ []) do
    receive do
      {:query, _sql, _params} -> collect_queries([:query | acc])
    after
      0 -> acc
    end
  end
end
