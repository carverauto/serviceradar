defmodule ServiceRadar.Notifications.DispatchWorkerTest do
  @moduledoc """
  The delivery worker's Oban contract.

  Nothing here needs a database, because the worker decides nothing about
  delivery - it maps `Dispatcher.deliver/2`'s four answers onto job outcomes and
  gets out of the way. What is worth testing is exactly that mapping, plus the
  two properties an operator would never see fail directly:

  1. `{:error, _}` must NOT become an Oban retry. `deliver/2` returns it for an
     attempt that is already finished and recorded, so handing it back would open
     a second retry budget on top of the delivery row's `max_attempts` - the
     failure mode is *more* pages, not fewer, and nothing in the UI explains
     them.
  2. `{:retry, at}` must snooze rather than fail, because Oban's snooze
     increments `max_attempts` and therefore does not consume the single
     execution this worker is given.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.DispatchWorker

  @delivery_id "0197b6f0-0000-7000-8000-000000000001"

  defp job(args), do: %Oban.Job{args: args}

  # A stand-in dispatcher. `deliver/2` is the only callback the worker uses, so
  # a module with one function is the whole seam - no database, no network, no
  # Oban.
  defmodule SentDispatcher do
    @moduledoc false
    def deliver(_id, _opts), do: {:ok, :sent}
  end

  defmodule SuppressedDispatcher do
    @moduledoc false
    def deliver(_id, _opts), do: {:ok, :suppressed}
  end

  defmodule DispatchingDispatcher do
    @moduledoc false
    def deliver(_id, _opts), do: {:ok, :dispatching}
  end

  defmodule RetryDispatcher do
    @moduledoc false
    def deliver(_id, opts), do: {:retry, Keyword.fetch!(opts, :retry_at)}
  end

  defmodule FailedDispatcher do
    @moduledoc false
    def deliver(_id, _opts), do: {:error, {:delivery_failed, "http_500"}}
  end

  defmodule ConfusedDispatcher do
    @moduledoc false
    def deliver(_id, _opts), do: :something_else
  end

  describe "args and job construction" do
    test "args carry a string key and an id, never a struct" do
      assert DispatchWorker.args(@delivery_id) == %{"delivery_id" => @delivery_id}
    end

    test "the job lands on the notifications queue with a single Oban attempt" do
      changes = DispatchWorker.job(@delivery_id).changes

      assert changes.queue == "notifications"
      assert changes.args == %{"delivery_id" => @delivery_id}
      # The delivery row owns retry through attempt_count/max_attempts/
      # next_attempt_at. A second Oban budget would multiply, not add.
      assert changes.max_attempts == 1
    end

    test "uniqueness is keyed on the delivery id across the incomplete states" do
      assert %{keys: [:delivery_id], period: :infinity, states: states} =
               DispatchWorker.job(@delivery_id).changes.unique

      # Deliberately NOT :all. Once an attempt has completed the row may
      # legitimately be owed another one, and a completed-inclusive unique key
      # would make the retry scan silently unable to re-enqueue it.
      refute :completed in states
      assert :available in states
      assert :scheduled in states
      assert :executing in states
    end

    test "a job option such as scheduled_at still reaches the job" do
      at = ~U[2026-08-09 12:00:00.000000Z]

      assert DispatchWorker.job(@delivery_id, scheduled_at: at).changes.scheduled_at == at
    end
  end

  describe "outcome mapping" do
    test "a sent delivery completes the job" do
      assert :ok =
               DispatchWorker.dispatch(job(%{"delivery_id" => @delivery_id}),
                 dispatcher: SentDispatcher
               )
    end

    test "a suppressed delivery completes the job, because it is fully recorded" do
      assert :ok =
               DispatchWorker.dispatch(job(%{"delivery_id" => @delivery_id}),
                 dispatcher: SuppressedDispatcher
               )
    end

    test "an accepted agent command completes the job while its receipt remains pending" do
      assert :ok =
               DispatchWorker.dispatch(job(%{"delivery_id" => @delivery_id}),
                 dispatcher: DispatchingDispatcher
               )
    end

    test "a retryable delivery snoozes until the instant the row now holds" do
      now = ~U[2026-08-09 12:00:00.000000Z]
      retry_at = DateTime.add(now, 90, :second)

      assert {:snooze, 90} =
               DispatchWorker.dispatch(job(%{"delivery_id" => @delivery_id}),
                 dispatcher: RetryDispatcher,
                 retry_at: retry_at,
                 now: now
               )
    end

    test "a retry instant that has already passed snoozes by the minimum, not by zero" do
      now = ~U[2026-08-09 12:00:00.000000Z]
      retry_at = DateTime.add(now, -30, :second)

      # Oban rejects a non-positive snooze, and a delivery whose next_attempt_at
      # is in the past is owed now.
      assert {:snooze, 1} =
               DispatchWorker.dispatch(job(%{"delivery_id" => @delivery_id}),
                 dispatcher: RetryDispatcher,
                 retry_at: retry_at,
                 now: now
               )
    end

    test "a recorded failure completes the job instead of asking Oban to retry" do
      # The delivery row is the system of record and already holds the failure.
      # Returning {:error, _} here would hand the delivery an invisible second
      # retry budget that max_attempts does not bound.
      assert :ok =
               DispatchWorker.dispatch(job(%{"delivery_id" => @delivery_id}),
                 dispatcher: FailedDispatcher
               )
    end

    test "an unrecognised dispatcher result completes the job rather than crashing the queue" do
      assert :ok =
               DispatchWorker.dispatch(job(%{"delivery_id" => @delivery_id}),
                 dispatcher: ConfusedDispatcher
               )
    end
  end

  describe "malformed args" do
    test "a job with no delivery id is cancelled, not retried" do
      assert {:cancel, :missing_delivery_id} =
               DispatchWorker.dispatch(job(%{}), dispatcher: SentDispatcher)
    end

    test "a non-binary delivery id is cancelled" do
      assert {:cancel, :missing_delivery_id} =
               DispatchWorker.dispatch(job(%{"delivery_id" => 42}), dispatcher: SentDispatcher)
    end
  end

  describe "idempotency" do
    test "re-running against an already-sent row is a no-op" do
      # The guard lives in Dispatcher.deliver/2 - a terminal row answers from its
      # own state without contacting anything - so re-running the worker simply
      # repeats the same answer. This is the ReportDeliveryWorker `:already_sent`
      # precedent, asserted from the worker's side.
      job = job(%{"delivery_id" => @delivery_id})

      assert :ok = DispatchWorker.dispatch(job, dispatcher: SentDispatcher)
      assert :ok = DispatchWorker.dispatch(job, dispatcher: SentDispatcher)
    end
  end
end
