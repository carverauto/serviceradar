defmodule ServiceRadar.Notifications.SilenceExpiryWorkerTest do
  @moduledoc """
  The silence sweeper's ordering, its bounded failure handling, and the claim its
  idempotency actually rests on.

  That last one is the reason this file exists rather than only a database test.
  The worker has no `:already_transitioned` guard: it is safe to re-run **because
  the reads exclude the target state**, so a row it already moved is not returned
  again. That is a property of `NotificationSilence`'s `:due_to_activate` and
  `:due_to_expire` filters, and it is asserted here directly against the resource
  - a rename or a widened filter would otherwise turn every repeated tick into an
  `AshStateMachine` invalid-transition error, and only in production.

  Expiry running before activation is likewise not cosmetic. A silence that
  should have expired but is still `:active` withholds pages an operator is owed;
  one that should have activated but has not produces one page too many. Missing
  a page is the worse failure, so releasing suppression is the half that runs
  first and the half that survives a tick that dies partway through.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadar.Notifications.SilenceExpiryWorker

  @now ~U[2026-08-09 12:00:00.000000Z]

  defp job, do: %Oban.Job{args: %{}}

  defp seams(rows) do
    test = self()

    [
      now: @now,
      reader: fn action, now, opts ->
        send(test, {:read, action, now, Keyword.fetch!(opts, :limit)})
        {:ok, Map.get(rows, action, [])}
      end,
      writer: fn silence, action, _opts ->
        send(test, {:write, silence.id, action})
        {:ok, silence}
      end
    ]
  end

  defp silence(id), do: %{id: id}

  describe "the read/update pairs" do
    test "both actions in every pair exist on the resource" do
      for {read_action, update_action} <- SilenceExpiryWorker.passes() do
        assert %{type: :read} = Info.action(NotificationSilence, read_action)
        assert %{type: :update} = Info.action(NotificationSilence, update_action)
      end
    end

    test "each read takes the :at argument the sweeper passes it" do
      for {read_action, _update_action} <- SilenceExpiryWorker.passes() do
        action = Info.action(NotificationSilence, read_action)
        assert Enum.any?(action.arguments, &(&1.name == :at))
      end
    end

    test "expiry runs before activation" do
      assert SilenceExpiryWorker.passes() == [
               {:due_to_expire, :expire},
               {:due_to_activate, :activate}
             ]
    end

    test "idempotency comes from the selection: each read excludes its own target state" do
      # `:due_to_expire` selects :scheduled/:active and writes :expired;
      # `:due_to_activate` selects :scheduled and writes :active. A row already
      # transitioned is therefore no longer returned, which is what makes a
      # repeated tick a no-op instead of an invalid-transition error.
      expire = inspect(Info.action(NotificationSilence, :due_to_expire).filter)
      activate = inspect(Info.action(NotificationSilence, :due_to_activate).filter)

      assert expire =~ "state in [:scheduled, :active]"
      refute expire =~ ":expired"

      assert activate =~ "state == :scheduled"
      refute activate =~ ":active"
    end
  end

  describe "sweeping" do
    test "both passes run, in order, against the same instant" do
      opts =
        seams(%{
          due_to_expire: [silence("expire-1")],
          due_to_activate: [silence("activate-1")]
        })

      assert :ok = SilenceExpiryWorker.sweep(job(), opts)

      assert_received {:read, :due_to_expire, @now, _limit}
      assert_received {:write, "expire-1", :expire}
      assert_received {:read, :due_to_activate, @now, _limit}
      assert_received {:write, "activate-1", :activate}
    end

    test "only the rows the reads return are driven" do
      opts = seams(%{due_to_expire: [silence("expire-1")]})

      assert :ok = SilenceExpiryWorker.sweep(job(), opts)

      assert_received {:write, "expire-1", :expire}
      refute_received {:write, _id, :activate}
    end

    test "an empty sweep writes nothing" do
      assert :ok = SilenceExpiryWorker.sweep(job(), seams(%{}))

      refute_received {:write, _id, _action}
    end

    test "every read is bounded" do
      assert :ok = SilenceExpiryWorker.sweep(job(), seams(%{}))

      assert_received {:read, :due_to_expire, @now, limit}
      assert is_integer(limit) and limit > 0
    end

    test "an explicit limit wins over the configured default" do
      assert :ok = SilenceExpiryWorker.sweep(job(), Keyword.put(seams(%{}), :limit, 3))

      assert_received {:read, :due_to_expire, @now, 3}
    end
  end

  describe "failure isolation" do
    test "a row that changed underneath is skipped, not raised" do
      # A concurrent :cancel is the realistic case. One cancelled silence must
      # not stop the tick from expiring the rest.
      test = self()

      opts =
        %{due_to_expire: [silence("gone"), silence("expire-2")]}
        |> seams()
        |> Keyword.put(:writer, fn
          %{id: "gone"}, _action, _opts ->
            {:error, :no_such_transition}

          silence, action, _opts ->
            send(test, {:write, silence.id, action})
            {:ok, silence}
        end)

      assert :ok = SilenceExpiryWorker.sweep(job(), opts)

      assert_received {:write, "expire-2", :expire}
    end

    test "a failed read does not stop the other pass" do
      test = self()

      opts =
        %{due_to_activate: [silence("activate-1")]}
        |> seams()
        |> Keyword.put(:reader, fn
          :due_to_expire, _now, _opts ->
            {:error, :timeout}

          action, _now, _opts ->
            send(test, {:read, action, @now, 1})
            {:ok, [silence("activate-1")]}
        end)

      assert :ok = SilenceExpiryWorker.sweep(job(), opts)

      assert_received {:write, "activate-1", :activate}
    end
  end

  describe "oban options" do
    test "the sweep is a singleton on the notifications queue with one attempt" do
      changes = SilenceExpiryWorker.new(%{}).changes

      assert changes.queue == "notifications"
      # A failed tick is superseded a minute later by a fresh scan; re-running a
      # stale scan is strictly worse than re-scanning.
      assert changes.max_attempts == 1
      assert %{period: :infinity} = changes.unique
    end
  end
end
