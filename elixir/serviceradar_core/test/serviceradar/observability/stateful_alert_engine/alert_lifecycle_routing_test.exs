defmodule ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycleRoutingTest do
  @moduledoc """
  The contract between the three routing requests the alert lifecycle emits and
  the worker that has to act on them.

  `AlertLifecycle` fires, resolves, and re-notifies; each emits one
  `RoutingWorker` job whose `lifecycle_reason` is half of
  `Dedupe.routing_request_key/1`. `RoutingWorker` maps an unrecognised reason to
  `{:cancel, :unknown_lifecycle_reason}` - the job is discarded on arrival, the
  incident is never routed, and no delivery row is ever written to say so. A
  reason that is merely plausible (`:first_notify` for `:fire`, `:resolved` for
  `:resolve`) therefore produces silence that looks exactly like "nothing
  matched", which is the failure design D5 exists to prevent.

  So the reasons are pinned end to end here: build the job the lifecycle would
  build, hand it to the worker, and assert the dispatcher is actually asked to
  route it. No database and no queue - the dispatcher and the fan-out are both
  injected.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.RoutingWorker

  @alert_id "3d1a0f22-6c48-4b1f-9d3c-7e5a2b0c9f11"

  # What each lifecycle entry point emits.
  #
  #   AlertLifecycle.create_event_and_alert/4 -> :fire
  #   AlertLifecycle.resolve_alert/4          -> :resolve
  #   AlertLifecycle.send_renotify/4          -> :renotify
  #
  # Alert.:send_notification emits :fire as well, deliberately: the AshOban
  # first-notification safety net and the lifecycle converge on one routing
  # request key so `Dispatcher.route/3` resolves the second to the first one's
  # work instead of paging twice.
  @emitted_reasons [:fire, :resolve, :renotify]

  defmodule StubDispatcher do
    @moduledoc false

    def route(alert_id, lifecycle_reason, opts) do
      send(self(), {:routed, alert_id, lifecycle_reason, opts})
      {:ok, %{planned: [], suppressed: []}}
    end
  end

  describe "every reason the lifecycle emits" do
    test "reaches the dispatcher instead of being cancelled" do
      for reason <- @emitted_reasons do
        assert :ok = perform(@alert_id, reason)

        assert_received {:routed, @alert_id, ^reason, _opts},
                        "#{inspect(reason)} did not reach the dispatcher"
      end
    end

    test "builds args with string keys and no structs" do
      for reason <- @emitted_reasons do
        args = RoutingWorker.args(@alert_id, reason)

        assert args == %{
                 "alert_id" => @alert_id,
                 "lifecycle_reason" => Atom.to_string(reason),
                 "step_number" => nil,
                 "dedupe_key" => nil
               }
      end
    end

    test "queues on :notifications" do
      for reason <- @emitted_reasons do
        job = build_job(@alert_id, reason)
        assert job.queue == "notifications"
        assert job.worker == "ServiceRadar.Notifications.RoutingWorker"
      end
    end
  end

  describe "a reason the worker does not know" do
    test "is cancelled, and routes nothing" do
      # The regression guard. `:first_notify` and `:resolved` are the two names
      # that read correctly and route nothing at all.
      for reason <- [:first_notify, :resolved, :recovered] do
        assert {:cancel, :unknown_lifecycle_reason} = perform(@alert_id, reason)
        refute_received {:routed, _alert_id, _reason, _opts}
      end
    end
  end

  defp perform(alert_id, reason) do
    alert_id
    |> build_job(reason)
    |> RoutingWorker.route(dispatcher: StubDispatcher, enqueue: fn _id -> {:ok, :queued} end)
  end

  defp build_job(alert_id, reason) do
    alert_id
    |> RoutingWorker.job(reason)
    |> Ecto.Changeset.apply_changes()
  end
end
