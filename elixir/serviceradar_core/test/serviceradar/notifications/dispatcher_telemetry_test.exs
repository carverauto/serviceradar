defmodule ServiceRadar.Notifications.DispatcherTelemetryTest do
  @moduledoc """
  The telemetry the dispatcher actually emits on the real path.

  `ServiceRadar.Notifications.TelemetryTest` pins the event contract without a
  database; this pins that the dispatcher reaches those emitters at the right
  moments and hands them the right row. The two halves are needed separately
  because the failure modes differ: a wrong contract produces a malformed event
  everywhere, while a missing call site produces a perfectly-shaped event that
  never fires - and a dashboard that reads zero is indistinguishable from a
  system with nothing to report.

  Two properties are worth the database on their own:

    * a rate-limited attempt emits NO dispatch-attempted event, because it never
      contacted anything and never burned an attempt. Counting it would make a
      busy channel look like a failing one.
    * end-to-end dispatch latency is measured from ALERT FIRE TIME rather than
      from the moment the rung was queued, which is the only measurement that
      shows a late page as late.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.RateLimiter
  alias ServiceRadar.Notifications.Telemetry
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.TestSupport

  require Ash.Query

  defmodule StubTransport do
    @moduledoc false

    @behaviour ServiceRadar.Notifications.Transport

    @impl true
    def capabilities, do: [:send, :test]

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(_request, _opts) do
      Process.get(:stub_result) || Result.delivered(external_correlation_id: "ts-1")
    end

    @impl true
    def test(request, opts), do: deliver(request, opts)

    def answer_with(result), do: Process.put(:stub_result, result)
  end

  @doc false
  def forward(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup context do
    Process.delete(:stub_result)

    handler = "notifications-dispatcher-telemetry-#{inspect(context.test)}"
    :telemetry.attach_many(handler, Telemetry.events(), &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, actor: SystemActor.system(:notification_dispatcher_telemetry_test)}
  end

  describe "route/3" do
    test "emits a routed event naming what the plan produced", %{actor: actor} do
      %{alert: alert, now: now} = routable!(actor)

      assert {:ok, %{planned: [_id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert_receive {:telemetry, [:serviceradar, :notifications, :routed], measurements,
                      metadata}

      assert measurements == %{count: 1, planned: 1, suppressed: 0}
      assert metadata.alert_id == alert.id
      assert metadata.lifecycle_reason == :fire
      assert metadata.matched_routes == 1
    end

    test "an unrouted alert emits routed with no matches and a suppressed event", %{actor: actor} do
      alert = create_alert!(actor)
      now = DateTime.add(alert.triggered_at, 1, :second)

      assert {:ok, %{planned: [], suppressed: [id]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      assert_receive {:telemetry, [:serviceradar, :notifications, :routed], routed,
                      routed_metadata}

      assert routed == %{count: 1, planned: 0, suppressed: 1}
      assert routed_metadata.matched_routes == 0

      assert_receive {:telemetry, [:serviceradar, :notifications, :suppressed], suppressed,
                      metadata}

      assert suppressed == %{count: 1, occurrence_count: 1}
      assert metadata.delivery_id == id
      assert metadata.suppression_reason == :no_matching_route
      assert metadata.phase == :routing
      # The tuple whose policy, step, and channel are all NULL.
      assert is_nil(metadata.channel_id)
      assert is_nil(metadata.policy_id)
    end

    test "a repeat carries the incremented occurrence count", %{actor: actor} do
      alert = create_alert!(actor)
      now = DateTime.add(alert.triggered_at, 1, :second)

      assert {:ok, _first} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)
      assert_receive {:telemetry, [:serviceradar, :notifications, :suppressed], first, _metadata}
      assert first.occurrence_count == 1

      assert {:ok, _second} =
               Dispatcher.route(alert.id, :fire,
                 actor: actor,
                 now: DateTime.add(now, 30, :second)
               )

      assert_receive {:telemetry, [:serviceradar, :notifications, :suppressed], second, _metadata}
      assert second.occurrence_count == 2
    end

    test "step 1 is not an escalation", %{actor: actor} do
      %{alert: alert, now: now} = routable!(actor)

      assert {:ok, _result} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      refute_received {:telemetry, [:serviceradar, :notifications, :escalated], _measurements,
                       _metadata}
    end

    test "a rung above step 1 emits an escalation event", %{actor: actor} do
      %{alert: alert, now: now, policy: policy} = routable!(actor, second_step_delay: 60)

      assert {:ok, %{planned: [_first]}} =
               Dispatcher.route(alert.id, :fire, actor: actor, now: now)

      later = DateTime.add(alert.triggered_at, 120, :second)

      assert {:ok, %{planned: [second_id]}} =
               Dispatcher.route(alert.id, :escalate, actor: actor, now: later)

      assert_receive {:telemetry, [:serviceradar, :notifications, :escalated], measurements,
                      metadata}

      assert measurements == %{count: 1, step_number: 2}
      assert metadata.delivery_id == second_id
      assert metadata.step_number == 2
      assert metadata.policy_id == policy.id
    end
  end

  describe "deliver/2" do
    test "a delivered result emits dispatched then sent", %{actor: actor} do
      %{id: id, now: now, channel: channel} = planned!(actor)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert_receive {:telemetry, [:serviceradar, :notifications, :dispatched], attempted,
                      attempted_metadata}

      assert attempted == %{count: 1, attempt: 1}
      assert attempted_metadata.delivery_id == id
      assert attempted_metadata.channel_id == channel.id
      assert attempted_metadata.provider_type == :native
      assert attempted_metadata.execution_route == :control_plane
      assert attempted_metadata.is_test == false

      assert_receive {:telemetry, [:serviceradar, :notifications, :sent], sent, sent_metadata}

      assert sent.count == 1
      assert sent.attempt == 1
      assert sent_metadata.channel_id == channel.id
    end

    test "dispatch latency is measured from alert fire time, not from queued_at", %{actor: actor} do
      %{id: id, alert: alert} = planned!(actor)

      # Five minutes after the alert fired. Measuring from `queued_at` would
      # report a near-zero latency for a page that took five minutes to land.
      now = DateTime.add(alert.triggered_at, 300, :second)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert_receive {:telemetry, [:serviceradar, :notifications, :sent], measurements, _metadata}

      assert measurements.dispatch_latency_ms == 300_000
    end

    test "a permanent failure emits dispatched then failed with its error class", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)
      StubTransport.answer_with(Result.permanent_failure("http_400"))

      assert {:error, {:delivery_failed, "http_400"}} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert_receive {:telemetry, [:serviceradar, :notifications, :dispatched], _attempted,
                      _attempted_metadata}

      assert_receive {:telemetry, [:serviceradar, :notifications, :failed], measurements,
                      metadata}

      assert measurements == %{count: 1, attempt: 1}
      assert metadata.error_class == "http_400"
    end

    test "a retryable failure emits retried and never failed", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)
      StubTransport.answer_with(Result.retryable_failure("http_503"))

      assert {:retry, _at} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert_receive {:telemetry, [:serviceradar, :notifications, :retried], measurements,
                      metadata}

      assert measurements.count == 1
      assert measurements.attempt == 1
      assert measurements.delay_ms > 0
      assert metadata.error_class == "http_503"

      # D4: retry is not failure. A delivery still inside its budget that
      # incremented the failure counter would report an error rate several times
      # the real one.
      refute_received {:telemetry, [:serviceradar, :notifications, :failed], _failed,
                       _failed_metadata}
    end

    test "a rate-limited attempt emits nothing at all", %{actor: actor} do
      %{id: id, now: now, channel: channel} = planned!(actor, rate_limit_per_minute: 1)
      on_exit(fn -> RateLimiter.reset(channel.id) end)

      assert RateLimiter.check_and_consume(channel.id, 1, now) == :ok

      assert {:retry, _at} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      # No attempt was consumed and nothing was contacted, so there is no
      # dispatch to count. An "attempted" that included this would make a
      # throttled channel indistinguishable from a broken one.
      refute_received {:telemetry, [:serviceradar, :notifications, :dispatched], _measurements,
                       _metadata}
    end

    test "suppression re-evaluated at dispatch emits the dispatch phase", %{actor: actor} do
      %{id: id, now: now, channel: channel} = planned!(actor)

      channel
      |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
      |> Ash.update!(actor: actor)

      assert {:ok, :suppressed} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert_receive {:telemetry, [:serviceradar, :notifications, :suppressed], measurements,
                      metadata}

      assert measurements.count == 1
      assert metadata.delivery_id == id
      assert metadata.suppression_reason == :channel_disabled
      assert metadata.phase == :dispatch
      assert metadata.channel_id == channel.id

      refute_received {:telemetry, [:serviceradar, :notifications, :dispatched], _dispatched,
                       _dispatched_metadata}
    end

    test "a failover emits both ends of the hop", %{actor: actor} do
      fallback = create_channel!(actor, [])
      %{id: id, now: now, channel: channel} = planned!(actor, fallback_channel_id: fallback.id)

      StubTransport.answer_with(Result.permanent_failure("http_400"))

      assert {:error, _reason} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert_receive {:telemetry, [:serviceradar, :notifications, :failed_over], measurements,
                      metadata}

      assert measurements == %{count: 1}
      assert metadata.delivery_id == id
      assert metadata.channel_id == channel.id
      assert metadata.fallback_channel_id == fallback.id
      assert is_binary(metadata.successor_delivery_id)
      refute metadata.successor_delivery_id == id
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp routable!(actor, opts \\ []) do
    channel = create_channel!(actor, [])
    policy = create_policy!(actor)
    step = create_step!(actor, policy, 1, 0)
    attach!(actor, step, channel)

    case Keyword.get(opts, :second_step_delay) do
      nil ->
        :ok

      delay ->
        second = create_step!(actor, policy, 2, delay)
        attach!(actor, second, channel)
    end

    create_route!(actor, policy)

    alert = create_alert!(actor)

    %{
      alert: alert,
      channel: channel,
      policy: policy,
      now: DateTime.add(alert.triggered_at, 1, :second)
    }
  end

  defp planned!(actor, channel_opts \\ []) do
    channel = create_channel!(actor, channel_opts)
    policy = create_policy!(actor)
    step = create_step!(actor, policy, 1, 0)
    attach!(actor, step, channel)
    create_route!(actor, policy)

    alert = create_alert!(actor)
    now = DateTime.add(alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

    # Drain the routing events so a delivery assertion cannot match one of them.
    assert_receive {:telemetry, [:serviceradar, :notifications, :routed], _measurements,
                    _metadata}

    %{id: id, alert: alert, channel: channel, now: now}
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

  defp create_channel!(actor, opts) do
    provider = create_provider!(actor)

    attrs =
      opts
      |> Map.new()
      |> Map.merge(%{
        name: "channel-#{System.unique_integer([:positive])}",
        provider_id: provider.id,
        config: %{}
      })

    NotificationChannel
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
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
        match_expression: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
