defmodule ServiceRadar.Notifications.DispatcherRoutingTest do
  @moduledoc """
  `route/3`'s two load-bearing persistence properties.

  1. **Idempotency.** A duplicate lifecycle callback, an Oban retry, and a
     scheduler tick that overlaps the previous one all re-emit the same routing
     request. Re-emitting it must resolve to the existing work rather than a
     second page, or an alert storm becomes an alert storm times the number of
     retries.
  2. **The unrouted alert is recorded, never dropped.** An alert nobody wrote a
     route for is the one case that would otherwise produce nothing at all, and
     "nothing at all" is exactly the failure an operator cannot debug. Design D5
     requires a `NotificationDelivery` row with `:no_matching_route`, and
     requires a repeat of that identical decision to collapse onto the existing
     row rather than growing the table without bound.

  Both need a database, so this is the small DataCase companion to the pure
  suites the decision cores carry.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.TestSupport

  require Ash.Query

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:notification_dispatcher_test)}
  end

  describe "route/3 idempotency" do
    setup %{actor: actor} do
      channel = create_channel!(actor)
      policy = create_policy!(actor)
      step = create_step!(actor, policy, 1, 0)
      attach!(actor, step, channel)
      route = create_route!(actor, policy)

      {:ok, channel: channel, policy: policy, step: step, route: route}
    end

    test "plans one pending delivery per (step, channel)", %{actor: actor} do
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: [delivery_id], suppressed: []}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert [delivery] = deliveries_for(alert, actor)
      assert delivery.id == delivery_id
      assert delivery.state == :pending
      assert delivery.step_number == 1
      assert delivery.attempt_count == 0
    end

    test "the routing lifecycle reason lands on the delivery (task 4.3.3b)", %{actor: actor} do
      # Without this the reason stops at routing and nothing has it at render
      # time, so every notification renders as a trigger - and a resolving alert
      # tells PagerDuty to trigger on the dedup_key of the incident it should
      # have closed.
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: [_id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert [delivery] = deliveries_for(alert, actor)
      assert delivery.lifecycle_reason == :fire
      assert Dispatcher.event_action(delivery.lifecycle_reason) == :trigger
    end

    test "a resolve routes as a resolve, not a trigger", %{actor: actor} do
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: [_id]}} =
               Dispatcher.route(alert.id, :resolve, actor: actor, now: now)

      assert [delivery] = deliveries_for(alert, actor)
      assert delivery.lifecycle_reason == :resolve
      assert Dispatcher.event_action(delivery.lifecycle_reason) == :resolve
    end

    test "a second identical request creates nothing", %{actor: actor} do
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: [_id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert {:ok, %{planned: [], suppressed: []}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert length(deliveries_for(alert, actor)) == 1
    end

    test "a later tick of the same request still creates nothing", %{actor: actor} do
      # The exclusion is keyed on the instant the rung was OWED, not on when the
      # scheduler woke, so a tick a minute later resolves to the same dispatch.
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: [_id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      later = DateTime.add(now, 60, :second)
      assert {:ok, %{planned: []}} = Dispatcher.route(alert.id, :fire, actor: actor, now: later)

      assert length(deliveries_for(alert, actor)) == 1
    end

    test "a different lifecycle reason does not duplicate the same rung", %{actor: actor} do
      # `lifecycle_reason` distinguishes routing REQUESTS, not dispatches. Two
      # requests that resolve to the same (step, channel, due_at) are the same
      # page, and sending it twice because the second request was labelled
      # differently is the bug the exclusion exists to prevent.
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: [_id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert {:ok, %{planned: []}} =
               Dispatcher.route(alert.id, :escalate, actor: actor, now: now)

      assert length(deliveries_for(alert, actor)) == 1
    end

    test "the delivery carries the snapshot that outlives the alert", %{actor: actor} do
      {alert, now} = fired_alert!(actor)

      assert {:ok, _result} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)
      assert [delivery] = deliveries_for(alert, actor)

      # AlertsRetentionWorker hard deletes alerts after three days and the FK is
      # nilify, so a delivery whose snapshot is empty is unreadable the moment
      # its alert is pruned.
      assert delivery.alert_snapshot["id"] == alert.id
      assert delivery.alert_snapshot["title"] == alert.title
      assert delivery.alert_snapshot["severity"] == "critical"
    end

    test "the delivery resolves max_attempts and the payload format up front", %{
      actor: actor,
      channel: channel
    } do
      {alert, now} = fired_alert!(actor)

      assert {:ok, _result} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)
      assert [delivery] = deliveries_for(alert, actor)

      assert delivery.max_attempts == channel.max_attempts
      assert delivery.execution_route == :control_plane
      # Design G7/G8: written BEFORE dispatch, so the row stays explicable after
      # the provider's format list or definition version moves on.
      assert delivery.payload_format == :json
      assert delivery.provider_version == 1
    end

    test "next_attempt_at is populated so the retry scan can recover the row", %{actor: actor} do
      {alert, now} = fired_alert!(actor)

      assert {:ok, _result} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)
      assert [delivery] = deliveries_for(alert, actor)

      assert delivery.next_attempt_at

      # A pending row whose Oban job was lost is still owed. `:retry_due` finds
      # it only because routing stamped `next_attempt_at`.
      assert %{retry: retry_ids} =
               Dispatcher.due(DateTime.add(now, 5, :second), actor: actor, limit: 50)

      assert delivery.id in retry_ids
    end

    test "an unknown alert is an error, not a silent no-op", %{actor: actor} do
      assert {:error, :alert_not_found} =
               Dispatcher.route(Ash.UUIDv7.generate(), :fire,
                 actor: actor,
                 now: DateTime.utc_now()
               )
    end
  end

  describe "route/3 with no matching route" do
    test "records one suppressed delivery with :no_matching_route", %{actor: actor} do
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: [], suppressed: [delivery_id]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert [delivery] = deliveries_for(alert, actor)
      assert delivery.id == delivery_id
      assert delivery.state == :suppressed
      assert delivery.suppression_reason == :no_matching_route
      assert delivery.occurrence_count == 1
    end

    test "is visible through the same Delivery Log read as every other withheld one", %{
      actor: actor
    } do
      # "You were never paged and nobody can tell you why" is the failure this
      # row exists to prevent, so it has to arrive through the SAME query the
      # Delivery Log uses for a silence or an acknowledgement - not through a
      # special case an operator has to know to look for.
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{suppressed: [delivery_id]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      withheld =
        NotificationDelivery
        |> Ash.Query.for_read(:suppressed)
        |> Ash.read!(actor: actor)

      assert delivery_id in Enum.map(withheld, & &1.id)
    end

    test "a repeat of the identical decision collapses onto the existing row", %{actor: actor} do
      # Design D5: record every withheld decision, but do not let a long-lived
      # one grow the table without bound. The identity tuple carries NULLs in
      # the policy/step/channel positions for an unrouted alert, which is why
      # the backing index is NULLS NOT DISTINCT.
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{suppressed: [id]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert {:ok, %{suppressed: [^id]}} =
               Dispatcher.route(alert.id, :fire,
                 actor: actor,
                 now: DateTime.add(now, 30, :second)
               )

      assert [delivery] = deliveries_for(alert, actor)
      assert delivery.occurrence_count == 2
      assert delivery.last_evaluated_at
    end

    test "an unrouted alert never appears as escalation work", %{actor: actor} do
      # D8: the scheduler drives continuation only. An alert whose only record is
      # a suppressed decision has never been notified, and originating its first
      # notification is AlertLifecycle's alone.
      {alert, now} = fired_alert!(actor)

      assert {:ok, _result} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)
      assert %{escalation: escalation} = Dispatcher.due(now, actor: actor, limit: 200)

      refute alert.id in escalation
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp deliveries_for(alert, actor) do
    NotificationDelivery
    |> Ash.Query.filter(alert_id == ^alert.id)
    |> Ash.read!(actor: actor)
  end

  # `Alert.triggered_at` is `:utc_datetime`, so the fire time is truncated to the
  # second while a wall-clock `now` captured in `setup` carries microseconds and
  # is frequently EARLIER than the alert it precedes. Deriving the decision
  # instant from the alert removes the race outright, and it is also what a
  # scheduler tick genuinely looks like: a moment after the alert fired.
  defp fired_alert!(actor) do
    alert = create_alert!(actor)
    {alert, DateTime.add(alert.triggered_at, 1, :second)}
  end

  defp create_alert!(actor) do
    Alert
    |> Ash.Changeset.for_create(
      :trigger,
      %{
        title: "Device unreachable #{System.unique_integer([:positive])}",
        description: "ICMP failed three times",
        severity: :critical,
        source_type: :device,
        metadata: %{"alert_class" => "device_down"}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_provider!(actor) do
    NotificationProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_key: "webhook-#{System.unique_integer([:positive])}",
        provider_type: :native,
        display_name: "Test webhook",
        capabilities: [:send, :test],
        supported_routes: [:control_plane],
        payload_formats: [:json],
        config_schema: %{},
        implementation_module: "ServiceRadar.Notifications.Transports.GenericWebhook"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_channel!(actor) do
    provider = create_provider!(actor)

    NotificationChannel
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "channel-#{System.unique_integer([:positive])}",
        provider_id: provider.id,
        config: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_policy!(actor) do
    NotificationEscalationPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{name: "policy-#{System.unique_integer([:positive])}"},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_step!(actor, policy, step_number, delay_seconds) do
    NotificationEscalationStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        policy_id: policy.id,
        step_number: step_number,
        delay_seconds: delay_seconds,
        condition: :always
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp attach!(actor, step, channel) do
    NotificationEscalationStepChannel
    |> Ash.Changeset.for_create(:attach, %{step_id: step.id, channel_id: channel.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_route!(actor, policy) do
    NotificationRoute
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "route-#{System.unique_integer([:positive])}",
        escalation_policy_id: policy.id,
        # An empty document is the catch-all, which is what makes this fixture
        # about routing persistence rather than about predicate evaluation - the
        # Router suite already owns that.
        match_expression: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
