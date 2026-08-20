defmodule ServiceRadar.Monitoring.Changes.EnqueueRoutingRequestTest do
  @moduledoc """
  The alert action's entire notification behaviour: enqueue one routing request,
  decide nothing, and refuse to commit if the request could not be enqueued.

  No database. The change registers an `after_action` hook and the hook calls
  one injected function, so both are assertable as plain data.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.Changes.EnqueueRoutingRequest
  alias ServiceRadar.Notifications.RoutingWorker

  @alert_id "8f6c7b02-1f2a-4f0e-9a6b-2f7f1c2d3e40"

  # Every reason `AlertLifecycle` and `Alert.:send_notification` emit. The list
  # is repeated here on purpose: it is the contract between the emitters and the
  # worker, and a test that derived it from the worker could not detect a drift.
  @emitted_reasons [:fire, :resolve, :renotify]

  describe "the hook" do
    test "enqueues exactly one routing request for the alert the action wrote" do
      {result, calls} = run_hook(:fire, fn _id, _reason -> {:ok, %Oban.Job{id: 1}} end)

      assert {:ok, %Alert{id: @alert_id}} = result
      assert calls == [{@alert_id, :fire}]
    end

    test "carries the lifecycle reason it was configured with" do
      for reason <- @emitted_reasons do
        {_result, calls} = run_hook(reason, fn _id, _reason -> {:ok, %Oban.Job{id: 1}} end)
        assert calls == [{@alert_id, reason}]
      end
    end

    test "fails the action when the request could not be enqueued" do
      # The counter and the routing request must commit together. Swallowing
      # this would leave `notification_count` incremented with nothing queued,
      # and `Alert.:needs_notification` - which is `notification_count == 0` -
      # would never look at the alert again.
      {result, _calls} = run_hook(:fire, fn _id, _reason -> {:error, :oban_unavailable} end)

      assert {:error, message} = result
      assert message =~ @alert_id
      assert message =~ "oban_unavailable"
    end

    test "fails rather than enqueueing a request with no alert id" do
      opts = init!(lifecycle_reason: :fire, enqueue: fn _id, _reason -> {:ok, :unreachable} end)

      changeset =
        Alert
        |> Ash.Changeset.new()
        |> EnqueueRoutingRequest.change(opts, %{})

      assert [hook] = changeset.after_action
      assert {:error, message} = hook.(changeset, %Alert{id: nil})
      assert message =~ "without an alert id"
    end
  end

  describe "atomic/3" do
    test "registers the hook on the changeset the atomic update will run" do
      # An atomic update does not execute the changeset `change/3` was handed.
      # Ash builds a second one in `fully_atomic_changeset/4` and carries over
      # only `atomic_after_action`, which a hook registered from `change/3`
      # never reaches - changes run in the `:validate` phase and
      # `Ash.Changeset.after_action/3` fills that list only in `:pending`.
      #
      # Answering `:ok` here therefore updates the row and silently runs no
      # hook: `notification_count` says the alert was notified and no routing
      # request exists. Nothing surfaces it. This is the guard.
      opts = init!(lifecycle_reason: :fire, enqueue: fn _id, _reason -> {:ok, :enqueued} end)

      assert {:ok, changeset} =
               Alert
               |> Ash.Changeset.new()
               |> EnqueueRoutingRequest.atomic(opts, %{})

      assert [hook] = changeset.after_action
      assert {:ok, %Alert{id: @alert_id}} = hook.(changeset, %Alert{id: @alert_id})
    end
  end

  describe "init/1" do
    test "accepts every reason the lifecycle emits" do
      for reason <- @emitted_reasons do
        assert {:ok, opts} = EnqueueRoutingRequest.init(lifecycle_reason: reason)
        assert opts[:lifecycle_reason] == reason
      end
    end

    test "every emitted reason is one RoutingWorker will act on" do
      # `RoutingWorker` maps an unknown `lifecycle_reason` to
      # `{:cancel, :unknown_lifecycle_reason}`, so a reason that is merely
      # plausible - `:first_notify`, `:resolved` - produces a job that is
      # discarded on arrival and an incident that is never routed. Nothing else
      # in the system reports that as a failure.
      known = RoutingWorker.lifecycle_reasons()

      for reason <- @emitted_reasons do
        assert Map.fetch(known, Atom.to_string(reason)) == {:ok, reason}
      end
    end

    test "rejects a reason the routing worker does not accept" do
      assert_raise ArgumentError, ~r/:first_notify/, fn ->
        EnqueueRoutingRequest.init(lifecycle_reason: :first_notify)
      end
    end

    test "rejects a missing reason" do
      assert_raise ArgumentError, fn -> EnqueueRoutingRequest.init([]) end
    end
  end

  defp run_hook(reason, enqueue) do
    parent = self()
    ref = make_ref()

    recording = fn alert_id, lifecycle_reason ->
      send(parent, {ref, alert_id, lifecycle_reason})
      enqueue.(alert_id, lifecycle_reason)
    end

    opts = init!(lifecycle_reason: reason, enqueue: recording)

    changeset =
      Alert
      |> Ash.Changeset.new()
      |> EnqueueRoutingRequest.change(opts, %{})

    assert [hook] = changeset.after_action

    result = hook.(changeset, %Alert{id: @alert_id})

    {result, drain(ref)}
  end

  defp init!(opts) do
    {:ok, opts} = EnqueueRoutingRequest.init(opts)
    opts
  end

  defp drain(ref, acc \\ []) do
    receive do
      {^ref, alert_id, reason} -> drain(ref, [{alert_id, reason} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
