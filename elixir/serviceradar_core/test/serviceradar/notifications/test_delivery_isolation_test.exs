defmodule ServiceRadar.Notifications.TestDeliveryIsolationTest do
  @moduledoc """
  An operator's "send a test message" must be invisible to every alert-facing
  count and to every piece of state that decides whether a real page goes out.

  Design G9 makes that one flag rather than a rule at each call site: a delivery
  created by `:record_test_dispatch` carries `is_test: true`, `Transport.test/2`
  is the callback that runs, and the four places that would otherwise be
  corrupted all filter on it. Those four are what this suite pins, because each
  failure is silent and each one is a page that does not happen:

    * `Alert.notification_count` - the counter `Alert.:needs_notification`
      reads, so a test send that bumped it would make the alert look already
      notified and the first REAL notification would never be originated;
    * dedupe state - `existing_dispatches` excludes test rows, so a test send
      does not make routing believe the rung is already dispatched;
    * throttle state - `last_dispatch_at` excludes test rows, so a test send
      does not start the `throttle_seconds` cadence window;
    * escalation position - `due/2`'s escalation scan excludes test rows, so an
      alert whose ONLY delivery is a test send is not treated as already
      notified and handed to the scheduler.

  The alert-facing count itself (`:countable_for_alert`) is asserted here too.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.Dedupe
  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.TestSupport

  require Ash.Query

  defmodule StubTransport do
    @moduledoc """
    Records which callback the dispatcher chose. `deliver/2` and `test/2` are
    deliberately NOT the same function here: which one ran is exactly what
    "a test send goes through `test/2`" means.
    """

    @behaviour ServiceRadar.Notifications.Transport

    @impl true
    def capabilities, do: [:send, :test]

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(request, _opts) do
      record(:deliver, request)
      Result.delivered(external_correlation_id: "live-1")
    end

    @impl true
    def test(request, _opts) do
      record(:test, request)
      Result.delivered(external_correlation_id: "test-1")
    end

    def calls, do: Enum.reverse(Process.get(:stub_calls, []))

    defp record(callback, request) do
      Process.put(:stub_calls, [{callback, request} | Process.get(:stub_calls, [])])
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    Process.delete(:stub_calls)

    actor = SystemActor.system(:notification_test_delivery_isolation_test)

    channel = create_channel!(actor)
    policy = create_policy!(actor)
    step = create_step!(actor, policy)
    attach!(actor, step, channel)
    # A throttle window far longer than the test, so a test send that leaked into
    # `last_dispatch_at` would withhold the real dispatch as `:throttled`.
    route = create_route!(actor, policy, throttle_seconds: 3_600)

    alert = create_alert!(actor)
    now = DateTime.add(alert.triggered_at, 1, :second)
    {:ok, dedupe_key} = Dedupe.dedupe_key(alert, route)

    test_delivery =
      test_dispatch!(actor, %{
        alert_id: alert.id,
        alert_snapshot: %{"id" => alert.id, "title" => alert.title, "severity" => "critical"},
        channel_id: channel.id,
        policy_id: policy.id,
        step_number: 1,
        dedupe_key: dedupe_key,
        max_attempts: channel.max_attempts,
        execution_route: :control_plane,
        payload_format: :json,
        queued_at: alert.triggered_at,
        next_attempt_at: alert.triggered_at
      })

    assert {:ok, :sent} =
             Dispatcher.deliver(test_delivery.id,
               actor: actor,
               now: now,
               transport: StubTransport
             )

    {:ok,
     actor: actor,
     alert: alert,
     channel: channel,
     route: route,
     now: now,
     dedupe_key: dedupe_key,
     test_delivery_id: test_delivery.id}
  end

  describe "the row a test send writes" do
    test "is flagged is_test and went through test/2, not deliver/2", context do
      %{actor: actor, test_delivery_id: id} = context

      delivery = reload!(id, actor)

      assert delivery.is_test
      assert delivery.state == :sent
      assert delivery.external_correlation_id == "test-1"

      assert [{:test, request}] = StubTransport.calls()
      # The flag reaches the transport too, so a provider that renders a "this is
      # a test" banner can, and a stream subscriber can filter.
      assert request.is_test
    end
  end

  describe "what a test send must not change" do
    test "does not touch Alert.notification_count", context do
      %{actor: actor, alert: alert} = context

      # `Alert.:needs_notification` is `notification_count == 0`. A test send
      # that bumped it would mark the alert notified and the first real
      # notification would never be originated at all.
      assert reload_alert!(alert.id, actor).notification_count == 0
    end

    test "is excluded from the alert-facing delivery count", context do
      %{actor: actor, alert: alert, test_delivery_id: id} = context

      countable =
        NotificationDelivery
        |> Ash.Query.for_read(:countable_for_alert, %{alert_id: alert.id})
        |> Ash.read!(actor: actor)

      assert countable == []

      # It is still in the Delivery Log; excluded from counts is not the same as
      # hidden, and an operator has to be able to see the test they just sent.
      assert id in (NotificationDelivery
                    |> Ash.Query.filter(alert_id == ^alert.id)
                    |> Ash.read!(actor: actor)
                    |> Enum.map(& &1.id))
    end

    test "does not move the alert into escalation work", context do
      %{actor: actor, alert: alert, now: now} = context

      # D8: the scheduler drives continuation only. The alert's only delivery is
      # a test send, so it has never been notified and the scheduler must not
      # originate its ladder.
      assert %{escalation: escalation} = Dispatcher.due(now, actor: actor, limit: 200)

      refute alert.id in escalation
    end

    test "does not make routing believe the rung was already dispatched", context do
      %{actor: actor, alert: alert, now: now, test_delivery_id: id} = context

      # The test row carries the same (dedupe_key, step_number, channel_id,
      # queued_at) tuple `existing_dispatches` matches on, so if it were not
      # excluded the real notification would be silently skipped.
      assert {:ok, %{planned: [planned_id], suppressed: []}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      refute planned_id == id
      assert reload!(planned_id, actor).state == :pending
    end

    test "does not start the throttle window for the real dispatch", context do
      %{actor: actor, alert: alert, now: now} = context

      assert {:ok, %{planned: [planned_id]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      # `throttle_seconds` is an hour and the test send landed seconds ago. If
      # `last_dispatch_at` counted it, this would come back `{:ok, :suppressed}`
      # with `:throttled` and nobody would be paged.
      assert {:ok, :sent} =
               Dispatcher.deliver(planned_id, actor: actor, now: now, transport: StubTransport)

      delivery = reload!(planned_id, actor)
      assert delivery.state == :sent
      assert is_nil(delivery.suppression_reason)
      refute delivery.is_test

      # And the real send took `deliver/2`, so the two callbacks are genuinely
      # selected by the flag rather than both resolving to the same code path.
      assert [{:test, _test_request}, {:deliver, _live_request}] = StubTransport.calls()
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp test_dispatch!(actor, attrs) do
    NotificationDelivery
    |> Ash.Changeset.for_create(:record_test_dispatch, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp reload!(id, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one!(actor: actor)
  end

  defp reload_alert!(id, actor) do
    Alert
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: actor)
  end

  defp create_alert!(actor) do
    Alert
    |> Ash.Changeset.for_create(
      :trigger,
      %{
        title: "Device unreachable #{System.unique_integer([:positive])}",
        description: "ICMP failed three times",
        severity: :critical,
        source_type: :device
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
    |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
    |> Ash.update!(actor: actor)
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

  defp create_step!(actor, policy) do
    NotificationEscalationStep
    |> Ash.Changeset.for_create(
      :create,
      %{policy_id: policy.id, step_number: 1, delay_seconds: 0, condition: :always},
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

  defp create_route!(actor, policy, opts) do
    attrs =
      opts
      |> Map.new()
      |> Map.merge(%{
        name: "route-#{System.unique_integer([:positive])}",
        escalation_policy_id: policy.id,
        match_expression: %{}
      })

    NotificationRoute
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end
end
