defmodule ServiceRadar.Notifications.DispatcherGroupingIntegrationTest do
  @moduledoc """
  Database-backed coverage for the persistence half of route grouping.

  The pure `GroupingTest` owns timing and snapshot calculations. These tests
  prove that `Dispatcher.route/3` applies those calculations to the durable
  delivery row and rolls the route transaction back when group history cannot
  be read.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationDeliveryMember
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.TestSupport

  require Ash.Query

  @dedupe_key "group:shared-destination"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:notification_grouping_integration_test)}
  end

  test "group_wait merges sibling alerts into one pending row without moving its due time", %{
    actor: actor
  } do
    route = create_group_route!(actor, group_wait_seconds: 30, group_interval_seconds: 300)
    first_alert = create_alert!(actor, "First device unreachable")
    first_now = DateTime.add(first_alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [delivery_id]}} =
             Dispatcher.route(first_alert.id, :fire, actor: actor, now: first_now)

    assert [first_delivery] = group_deliveries(route, actor)
    assert first_delivery.id == delivery_id
    assert first_delivery.state == :pending
    assert first_delivery.next_attempt_at == DateTime.add(first_delivery.queued_at, 30, :second)

    first_due_at = first_delivery.next_attempt_at
    second_alert = create_alert!(actor, "Second device unreachable")

    assert {:ok, %{planned: [^delivery_id]}} =
             Dispatcher.route(second_alert.id, :fire,
               actor: actor,
               now: DateTime.add(first_now, 10, :second)
             )

    assert [grouped] = group_deliveries(route, actor)
    assert grouped.id == delivery_id
    assert grouped.alert_id == first_alert.id
    assert grouped.next_attempt_at == first_due_at
    assert grouped.alert_snapshot["group_size"] == 2

    assert MapSet.new(grouped.alert_snapshot["grouped_alerts"], & &1["id"]) ==
             MapSet.new([first_alert.id, second_alert.id])

    assert MapSet.new(group_member_alert_ids(grouped.id, actor)) ==
             MapSet.new([first_alert.id, second_alert.id])

    # The member's own due instant, rather than the delivery anchor's queued_at,
    # is what makes a duplicate callback idempotent for a grouped sibling.
    assert {:ok, %{planned: []}} =
             Dispatcher.route(second_alert.id, :fire,
               actor: actor,
               now: DateTime.add(first_now, 11, :second)
             )

    assert [same_group] = group_deliveries(route, actor)
    assert same_group.id == delivery_id
    assert length(delivery_members(delivery_id, actor)) == 2
  end

  test "a later member of a sent group is held until group_interval elapses", %{actor: actor} do
    route = create_group_route!(actor, group_wait_seconds: 30, group_interval_seconds: 300)
    first_alert = create_alert!(actor, "Initial grouped incident")
    first_now = DateTime.add(first_alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [first_delivery_id]}} =
             Dispatcher.route(first_alert.id, :fire, actor: actor, now: first_now)

    sibling = create_alert!(actor, "Initial grouped sibling")

    assert {:ok, %{planned: [^first_delivery_id]}} =
             Dispatcher.route(sibling.id, :fire,
               actor: actor,
               now: DateTime.add(first_now, 5, :second)
             )

    sent =
      first_delivery_id
      |> reload_delivery!(actor)
      |> Ash.Changeset.for_update(:record_sent, %{}, actor: actor)
      |> Ash.update!(actor: actor)

    # Sibling membership survives the shared send. It must not be replanned as
    # though only the delivery row's anchor alert had fired.
    assert {:ok, %{planned: []}} =
             Dispatcher.route(sibling.id, :fire,
               actor: actor,
               now: DateTime.add(sent.finished_at, 1, :second)
             )

    second_alert = create_alert!(actor, "Later grouped incident")
    later_now = DateTime.add(sent.finished_at, 1, :second)

    assert {:ok, %{planned: [second_delivery_id]}} =
             Dispatcher.route(second_alert.id, :fire, actor: actor, now: later_now)

    refute second_delivery_id == first_delivery_id
    second_delivery = reload_delivery!(second_delivery_id, actor)

    assert second_delivery.state == :pending
    assert second_delivery.dedupe_key == @dedupe_key
    assert second_delivery.next_attempt_at == DateTime.add(sent.finished_at, 300, :second)
    assert DateTime.after?(second_delivery.next_attempt_at, later_now)
    assert length(group_deliveries(route, actor)) == 2
  end

  test "resolving a pending anchor removes only that member and re-anchors active siblings", %{
    actor: actor
  } do
    route = create_group_route!(actor, group_wait_seconds: 30, group_interval_seconds: 300)
    first_alert = create_alert!(actor, "Pending anchor")
    first_now = DateTime.add(first_alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [delivery_id]}} =
             Dispatcher.route(first_alert.id, :fire, actor: actor, now: first_now)

    sibling = create_alert!(actor, "Pending sibling")

    assert {:ok, %{planned: [^delivery_id]}} =
             Dispatcher.route(sibling.id, :fire,
               actor: actor,
               now: DateTime.add(first_now, 5, :second)
             )

    assert {:ok, %{cancelled: [], planned: []}} =
             Dispatcher.route(first_alert.id, :resolve,
               actor: actor,
               now: DateTime.add(first_now, 10, :second)
             )

    remaining = reload_delivery!(delivery_id, actor)
    assert remaining.state == :pending
    assert remaining.alert_id == sibling.id
    assert remaining.alert_snapshot["group_size"] == 1
    assert group_member_alert_ids(delivery_id, actor) == [sibling.id]

    assert {:ok, %{cancelled: [^delivery_id], planned: []}} =
             Dispatcher.route(sibling.id, :resolve,
               actor: actor,
               now: DateTime.add(first_now, 11, :second)
             )

    assert reload_delivery!(delivery_id, actor).state == :cancelled
    assert delivery_members(delivery_id, actor) == []
    assert length(group_deliveries(route, actor)) == 1
  end

  test "any sent group member closes the shared provider correlation exactly once", %{
    actor: actor
  } do
    route =
      create_group_route!(actor,
        group_wait_seconds: 30,
        group_interval_seconds: 300,
        resolve_notifies: true
      )

    first_alert = create_alert!(actor, "Sent group anchor")
    first_now = DateTime.add(first_alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [source_id]}} =
             Dispatcher.route(first_alert.id, :fire, actor: actor, now: first_now)

    sibling = create_alert!(actor, "Sent group sibling")

    assert {:ok, %{planned: [^source_id]}} =
             Dispatcher.route(sibling.id, :fire,
               actor: actor,
               now: DateTime.add(first_now, 5, :second)
             )

    source =
      source_id
      |> reload_delivery!(actor)
      |> Ash.Changeset.for_update(
        :record_sent,
        %{external_correlation_id: "provider-shared-correlation"},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert {:ok, %{planned: [resolution_id]}} =
             Dispatcher.route(sibling.id, :resolve,
               actor: actor,
               now: DateTime.add(source.finished_at, 1, :second)
             )

    resolution = reload_delivery!(resolution_id, actor)
    assert resolution.lifecycle_reason == :resolve
    assert resolution.alert_id == sibling.id
    assert resolution.external_correlation_id == source.external_correlation_id

    assert MapSet.new(group_member_alert_ids(resolution_id, actor)) ==
             MapSet.new([first_alert.id, sibling.id])

    assert {:ok, %{planned: []}} =
             Dispatcher.route(first_alert.id, :resolve,
               actor: actor,
               now: DateTime.add(source.finished_at, 2, :second)
             )

    assert {:ok, %{planned: []}} =
             Dispatcher.route(sibling.id, :resolve,
               actor: actor,
               now: DateTime.add(source.finished_at, 3, :second)
             )

    assert [only_resolution] =
             route
             |> group_deliveries(actor)
             |> Enum.filter(&(&1.lifecycle_reason == :resolve))

    assert only_resolution.id == resolution_id
  end

  test "distinct sent correlations each receive one closeout for a shared member", %{
    actor: actor
  } do
    route =
      create_group_route!(actor,
        group_wait_seconds: 30,
        group_interval_seconds: 300,
        resolve_notifies: true
      )

    first_alert = create_alert!(actor, "Multi-correlation anchor")
    first_now = DateTime.add(first_alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [source_id]}} =
             Dispatcher.route(first_alert.id, :fire, actor: actor, now: first_now)

    sibling = create_alert!(actor, "Multi-correlation sibling")

    assert {:ok, %{planned: [^source_id]}} =
             Dispatcher.route(sibling.id, :fire,
               actor: actor,
               now: DateTime.add(first_now, 5, :second)
             )

    first_source =
      source_id
      |> reload_delivery!(actor)
      |> Ash.Changeset.for_update(
        :record_sent,
        %{external_correlation_id: "correlation-one"},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    second_source =
      duplicate_sent_group!(
        first_source,
        sibling.id,
        "correlation-two",
        DateTime.add(first_source.finished_at, 60, :second),
        actor
      )

    assert {:ok, %{planned: resolution_ids}} =
             Dispatcher.route(sibling.id, :resolve,
               actor: actor,
               now: DateTime.add(second_source.finished_at, 1, :second)
             )

    assert length(resolution_ids) == 2

    assert MapSet.new(resolution_ids, fn id ->
             reload_delivery!(id, actor).external_correlation_id
           end) == MapSet.new(["correlation-one", "correlation-two"])

    assert {:ok, %{planned: []}} =
             Dispatcher.route(first_alert.id, :resolve,
               actor: actor,
               now: DateTime.add(second_source.finished_at, 2, :second)
             )

    assert route
           |> group_deliveries(actor)
           |> Enum.count(&(&1.lifecycle_reason == :resolve)) == 2
  end

  test "a stale fire callback cannot page after resolution won the lifecycle lock", %{
    actor: actor
  } do
    route = create_group_route!(actor, group_wait_seconds: 30, group_interval_seconds: 300)
    alert = create_alert!(actor, "Resolve-before-fire race")

    alert
    |> Ash.Changeset.for_update(:resolve, %{resolved_by: "grouping-race-test"}, actor: actor)
    |> Ash.update!(actor: actor)

    assert {:ok, %{planned: [], suppressed: []}} =
             Dispatcher.route(alert.id, :fire,
               actor: actor,
               now: DateTime.add(alert.triggered_at, 1, :second)
             )

    assert group_deliveries(route, actor) == []
  end

  test "a member write failure rolls the new delivery back", %{actor: actor} do
    route = create_group_route!(actor, group_wait_seconds: 30, group_interval_seconds: 300)
    alert = create_alert!(actor, "Member persistence failure")
    now = DateTime.add(alert.triggered_at, 1, :second)

    create_delivery_member = fn _attrs, _actor ->
      {:error, :injected_member_write_failure}
    end

    assert {:error,
            {:delivery_plan_persistence_failed,
             {:group_member_persistence_failed, :injected_member_write_failure}}} =
             Dispatcher.route(alert.id, :fire,
               actor: actor,
               now: now,
               create_delivery_member: create_delivery_member
             )

    assert group_deliveries(route, actor) == []
    assert delivery_members_for_alert(alert.id, actor) == []
  end

  test "an unreadable group history aborts routing before any delivery is created", %{
    actor: actor
  } do
    route = create_group_route!(actor, group_wait_seconds: 30, group_interval_seconds: 300)
    alert = create_alert!(actor, "History read failure")
    now = DateTime.add(alert.triggered_at, 1, :second)

    load_last_group_sent_at = fn _placement, _step_number, _channel_id, _actor ->
      {:error, :injected_group_history_failure}
    end

    assert {:error, {:group_history_unreadable, :injected_group_history_failure}} =
             Dispatcher.route(alert.id, :fire,
               actor: actor,
               now: now,
               load_last_group_sent_at: load_last_group_sent_at
             )

    assert group_deliveries(route, actor) == []
  end

  defp create_group_route!(actor, grouping_attrs) do
    {resolve_notifies, grouping_attrs} = Keyword.pop(grouping_attrs, :resolve_notifies, false)
    channel = create_channel!(actor)

    policy =
      NotificationEscalationPolicy
      |> Ash.Changeset.for_create(
        :create,
        %{name: unique("group-policy"), resolve_notifies: resolve_notifies},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step =
      NotificationEscalationStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          policy_id: policy.id,
          step_number: 1,
          delay_seconds: 0,
          condition: :always
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    NotificationEscalationStepChannel
    |> Ash.Changeset.for_create(:attach, %{step_id: step.id, channel_id: channel.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    route_attrs =
      grouping_attrs
      |> Map.new()
      |> Map.merge(%{
        name: unique("group-route"),
        escalation_policy_id: policy.id,
        match_expression: %{},
        dedupe_key_template: @dedupe_key
      })

    NotificationRoute
    |> Ash.Changeset.for_create(:create, route_attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_channel!(actor) do
    provider =
      NotificationProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_key: unique("group-webhook"),
          provider_type: :native,
          display_name: "Grouping test webhook",
          capabilities: [:send, :test],
          supported_routes: [:control_plane],
          payload_formats: [:json],
          config_schema: %{},
          implementation_module: "ServiceRadar.Notifications.Transports.GenericWebhook"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    NotificationChannel
    |> Ash.Changeset.for_create(
      :create,
      %{name: unique("group-channel"), provider_id: provider.id, config: %{}},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_alert!(actor, title) do
    Alert
    |> Ash.Changeset.for_create(
      :trigger,
      %{
        title: "#{title} #{System.unique_integer([:positive])}",
        description: "Grouping integration fixture",
        severity: :critical,
        source_type: :device,
        metadata: %{"alert_class" => "device_down"}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp group_deliveries(route, actor) do
    route_id = route.id

    NotificationDelivery
    |> Ash.Query.filter(route_id == ^route_id and dedupe_key == ^@dedupe_key)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(actor: actor)
  end

  defp reload_delivery!(id, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one!(actor: actor)
  end

  defp delivery_members(delivery_id, actor) do
    NotificationDeliveryMember
    |> Ash.Query.for_read(:for_delivery, %{delivery_id: delivery_id})
    |> Ash.read!(actor: actor)
  end

  defp delivery_members_for_alert(alert_id, actor) do
    NotificationDeliveryMember
    |> Ash.Query.for_read(:for_alert, %{alert_id: alert_id})
    |> Ash.read!(actor: actor)
  end

  defp group_member_alert_ids(delivery_id, actor) do
    delivery_id
    |> delivery_members(actor)
    |> Enum.map(& &1.alert_id)
    |> Enum.uniq()
  end

  defp duplicate_sent_group!(source, anchor_alert_id, correlation_id, queued_at, actor) do
    copy =
      NotificationDelivery
      |> Ash.Changeset.for_create(
        :record_dispatch,
        %{
          alert_id: anchor_alert_id,
          alert_snapshot: source.alert_snapshot,
          route_id: source.route_id,
          policy_id: source.policy_id,
          step_number: source.step_number,
          channel_id: source.channel_id,
          dedupe_key: source.dedupe_key,
          max_attempts: source.max_attempts,
          execution_route: source.execution_route,
          payload_format: source.payload_format,
          provider_version: source.provider_version,
          queued_at: queued_at,
          next_attempt_at: queued_at,
          lifecycle_reason: :renotify
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    Enum.each(delivery_members(source.id, actor), fn member ->
      NotificationDeliveryMember
      |> Ash.Changeset.for_create(
        :attach,
        %{
          delivery_id: copy.id,
          alert_id: member.alert_id,
          source_due_at: queued_at,
          alert_snapshot: member.alert_snapshot
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end)

    copy
    |> Ash.Changeset.for_update(
      :record_sent,
      %{external_correlation_id: correlation_id},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
