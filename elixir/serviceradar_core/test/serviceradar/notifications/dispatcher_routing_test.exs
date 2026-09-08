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
  alias ServiceRadar.Observability.StatefulAlertRule
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

    test "a resolve closes only destinations that received the incident", %{
      actor: actor,
      route: route,
      policy: policy,
      step: step,
      channel: sent_channel
    } do
      route = update_route!(actor, route, %{continue: true, priority: 10})
      never_sent_channel = create_channel!(actor)
      attach!(actor, step, never_sent_channel)

      no_close_policy = create_policy!(actor, %{resolve_notifies: false})
      no_close_step = create_step!(actor, no_close_policy, 1, 0)
      no_close_channel = create_channel!(actor)
      attach!(actor, no_close_step, no_close_channel)
      no_close_route = create_route!(actor, no_close_policy, %{priority: 20})

      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: fire_ids}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert length(fire_ids) == 3

      fire_deliveries = deliveries_for(alert, actor)
      sent = Enum.find(fire_deliveries, &(&1.channel_id == sent_channel.id))
      never_sent = Enum.find(fire_deliveries, &(&1.channel_id == never_sent_channel.id))
      no_close = Enum.find(fire_deliveries, &(&1.channel_id == no_close_channel.id))

      sent = mark_sent!(sent, actor, "incident-123")
      _no_close = mark_sent!(no_close, actor, "incident-no-close")

      _resolved =
        alert
        |> Ash.Changeset.for_update(:resolve, %{resolved_by: "routing-test"}, actor: actor)
        |> Ash.update!(actor: actor)

      assert {:ok, %{planned: [resolution_id], cancelled: [cancelled_id]}} =
               Dispatcher.route(alert.id, :resolve, actor: actor, now: now)

      assert cancelled_id == never_sent.id

      resolution = reload_delivery!(resolution_id, actor)
      assert resolution.lifecycle_reason == :resolve
      assert Dispatcher.event_action(resolution.lifecycle_reason) == :resolve
      assert resolution.route_id == route.id
      assert resolution.policy_id == policy.id
      assert resolution.channel_id == sent_channel.id
      assert resolution.step_number == sent.step_number
      assert resolution.dedupe_key == sent.dedupe_key
      assert resolution.external_correlation_id == "incident-123"

      assert reload_delivery!(never_sent.id, actor).state == :cancelled

      resolution_rows =
        alert
        |> deliveries_for(actor)
        |> Enum.filter(&(&1.lifecycle_reason == :resolve))

      assert Enum.map(resolution_rows, & &1.channel_id) == [sent_channel.id]
      refute Enum.any?(resolution_rows, &(&1.route_id == no_close_route.id))

      assert {:ok, %{planned: [], cancelled: []}} =
               Dispatcher.route(alert.id, :resolve, actor: actor, now: now)

      assert length(Enum.filter(deliveries_for(alert, actor), &(&1.lifecycle_reason == :resolve))) ==
               1
    end

    test "continued routes sharing one destination persist independently", %{
      actor: actor,
      route: first_route,
      channel: channel
    } do
      first_route = update_route!(actor, first_route, %{continue: true, priority: 10})
      second_policy = create_policy!(actor)
      second_step = create_step!(actor, second_policy, 1, 0)
      attach!(actor, second_step, channel)
      second_route = create_route!(actor, second_policy, %{priority: 20})
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: planned}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert length(planned) == 2
      deliveries = deliveries_for(alert, actor)

      assert MapSet.new(deliveries, & &1.route_id) ==
               MapSet.new([first_route.id, second_route.id])

      assert deliveries
             |> Enum.uniq_by(&{&1.channel_id, &1.step_number, &1.dedupe_key})
             |> length() == 1
    end

    test "a delivery create failure rolls back the whole route plan", %{
      actor: actor,
      step: step
    } do
      attach!(actor, step, create_channel!(actor))
      {alert, now} = fired_alert!(actor)
      counter_key = {__MODULE__, :create_count, make_ref()}

      create_delivery = fn action, attrs, create_actor ->
        count = Process.get(counter_key, 0) + 1
        Process.put(counter_key, count)

        if count == 2 do
          {:error, :injected_create_failure}
        else
          NotificationDelivery
          |> Ash.Changeset.for_create(action, attrs, actor: create_actor)
          |> Ash.create(actor: create_actor, return_notifications?: true)
        end
      end

      on_exit(fn -> Process.delete(counter_key) end)

      assert {:error, {:delivery_plan_persistence_failed, :injected_create_failure}} =
               Dispatcher.route(alert.id, :fire,
                 actor: actor,
                 now: now,
                 create_delivery: create_delivery
               )

      assert deliveries_for(alert, actor) == []
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

    test "an acknowledged alert remains due for an :always rung", %{
      actor: actor,
      policy: policy,
      channel: channel
    } do
      step_two = create_step!(actor, policy, 2, 300, :always)
      attach!(actor, step_two, channel)
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{planned: [_step_one]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      _acknowledged =
        alert
        |> Ash.Changeset.for_update(:acknowledge, %{acknowledged_by: "review-test"}, actor: actor)
        |> Ash.update!(actor: actor)

      due_at = DateTime.add(now, 300, :second)
      assert %{escalation: escalation} = Dispatcher.due(due_at, actor: actor, limit: 50)
      assert alert.id in escalation

      assert {:ok, %{planned: [step_two_id]}} =
               Dispatcher.route(alert.id, :escalate, actor: actor, now: due_at)

      assert reload_delivery!(step_two_id, actor).step_number == 2
    end

    test "renotify cadence appears in continuation work", %{actor: actor} do
      rule = create_rule!(actor, 60)

      alert =
        create_alert!(actor, %{
          "alert_class" => "device_down",
          "incident_rule_id" => rule.id
        })

      now = DateTime.add(alert.triggered_at, 1, :second)
      assert {:ok, %{planned: [_id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      notified =
        alert
        |> Ash.Changeset.for_update(:record_notification, %{}, actor: actor)
        |> Ash.update!(actor: actor)

      before_due = DateTime.add(notified.last_notification_at, 59, :second)
      assert %{renotify: renotify} = Dispatcher.due(before_due, actor: actor, limit: 50)
      refute alert.id in renotify

      due_at = DateTime.add(notified.last_notification_at, 60, :second)
      assert %{renotify: renotify} = Dispatcher.due(due_at, actor: actor, limit: 50)
      assert alert.id in renotify
    end
  end

  describe "a suppressed dispatch to a :stream channel (task 4.4.2a)" do
    test "publishes no envelope and still records the suppression", %{actor: actor} do
      # Two surfaces, and conflating them is the easy mistake: the firehose must
      # carry NOTHING for a withheld notification, while the Delivery Log must
      # still show it and say why. "Nothing published" and "nothing recorded" are
      # very different failures and only the first is correct here.
      _channel = create_stream_channel!(actor)
      {alert, now} = fired_alert!(actor)

      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "notifications:stream")

      # Prove the subscription is live BEFORE relying on a refute. Without this
      # the refute below passes just as happily against a topic nobody is
      # listening to, which is the classic vacuous negative assertion.
      Phoenix.PubSub.broadcast(
        ServiceRadar.PubSub,
        "notifications:stream",
        {:notification_envelope, %{"probe" => true}}
      )

      assert_receive {:notification_envelope, %{"probe" => true}}, 500

      assert {:ok, %{planned: [], suppressed: [delivery_id]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      # Suppression is decided BEFORE a transport is called, so there is no
      # "suppressed envelope" for a subscriber to receive - by construction, not
      # by a filter that could be forgotten.
      refute_receive {:notification_envelope, _envelope}, 200

      assert [delivery] = deliveries_for(alert, actor)
      assert delivery.id == delivery_id
      assert delivery.state == :suppressed
      assert delivery.suppression_reason
    end

    test "the withheld row reaches the Delivery Log through the shared read", %{actor: actor} do
      _channel = create_stream_channel!(actor)
      {alert, now} = fired_alert!(actor)

      assert {:ok, %{suppressed: [delivery_id]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      withheld =
        NotificationDelivery
        |> Ash.Query.for_read(:suppressed)
        |> Ash.read!(actor: actor)

      row = Enum.find(withheld, &(&1.id == delivery_id))

      assert row, "a suppressed stream dispatch must not be invisible to the Delivery Log"
      assert row.suppression_reason
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

    test "an old unrouted alert cannot consume the bounded escalation page", %{actor: actor} do
      {unrouted, old_now} = fired_alert!(actor)
      assert {:ok, _result} = Dispatcher.route(unrouted.id, :fire, actor: actor, now: old_now)

      channel = create_channel!(actor)
      policy = create_policy!(actor)
      step = create_step!(actor, policy, 1, 0)
      attach!(actor, step, channel)
      create_route!(actor, policy)

      {notified, now} = fired_alert!(actor)

      assert {:ok, %{planned: [_id]}} =
               Dispatcher.route(notified.id, :fire, actor: actor, now: now)

      assert %{escalation: [only]} = Dispatcher.due(now, actor: actor, limit: 1)
      assert only == notified.id
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

  defp create_alert!(actor, metadata \\ %{"alert_class" => "device_down"}) do
    Alert
    |> Ash.Changeset.for_create(
      :trigger,
      %{
        title: "Device unreachable #{System.unique_integer([:positive])}",
        description: "ICMP failed three times",
        severity: :critical,
        source_type: :device,
        metadata: metadata
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

  defp create_stream_channel!(actor) do
    # `implementation_module` MUST be nil: the
    # notification_providers_native_module CHECK admits one only on a :native
    # row, and `:stream` is a provider_type rather than an extensibility tier.
    provider =
      NotificationProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_key: "stream-#{System.unique_integer([:positive])}",
          provider_type: :stream,
          display_name: "Test firehose",
          capabilities: [:send, :test],
          supported_routes: [:control_plane],
          payload_formats: [:json],
          config_schema: %{},
          implementation_module: nil
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    NotificationChannel
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "stream-channel-#{System.unique_integer([:positive])}",
        provider_id: provider.id,
        config: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_policy!(actor, attrs \\ %{}) do
    NotificationEscalationPolicy
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: "policy-#{System.unique_integer([:positive])}"}, attrs),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_step!(actor, policy, step_number, delay_seconds, condition \\ :always) do
    NotificationEscalationStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        policy_id: policy.id,
        step_number: step_number,
        delay_seconds: delay_seconds,
        condition: condition
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

  defp create_route!(actor, policy, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "route-#{System.unique_integer([:positive])}",
          escalation_policy_id: policy.id,
          # An empty document is the catch-all, which is what makes this fixture
          # about routing persistence rather than about predicate evaluation - the
          # Router suite already owns that.
          match_expression: %{}
        },
        attrs
      )

    NotificationRoute
    |> Ash.Changeset.for_create(
      :create,
      attrs,
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp update_route!(actor, route, attrs) do
    route
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp mark_sent!(delivery, actor, external_correlation_id) do
    delivery
    |> Ash.Changeset.for_update(
      :record_sent,
      %{external_correlation_id: external_correlation_id},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp reload_delivery!(id, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one!(actor: actor)
  end

  defp create_rule!(actor, renotify_seconds) do
    StatefulAlertRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "rule-#{System.unique_integer([:positive])}",
        renotify_seconds: renotify_seconds
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
