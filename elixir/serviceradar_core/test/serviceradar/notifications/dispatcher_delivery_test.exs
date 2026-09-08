defmodule ServiceRadar.Notifications.DispatcherDeliveryTest do
  @moduledoc """
  `deliver/2` against a stub transport.

  The point of the `:transport` seam is that the whole dispatch path - suppression
  re-evaluation, the rate-limit reservation, secret resolution, template
  resolution, rendering, and the mapping of a transport result onto the delivery
  state machine - is exercisable with no network. What is asserted here is the
  half that is easy to get subtly wrong and impossible to notice in production
  until an incident:

    * a retryable failure keeps the row `:pending` and NEVER visits `:failed`,
      because `read :retry_due` selects `:pending` and a row that passed through
      `:failed` is terminal and gone;
    * a rate-limited attempt burns no attempt at all;
    * suppression is re-evaluated at dispatch, not trusted from routing time;
    * failover takes exactly one hop and back-references its origin.
  """

  use ServiceRadar.DataCase, async: true

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
  alias ServiceRadar.Notifications.RateLimiter
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.TestSupport

  require Ash.Query

  defmodule StubTransport do
    @moduledoc """
    A `Transport` that answers from the calling process's dictionary.

    The dispatcher invokes the transport inline, so the stub shares a process
    with the test and needs no supervision, no mock library, and no message
    passing.
    """

    @behaviour ServiceRadar.Notifications.Transport

    @impl true
    def capabilities, do: [:send, :test]

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(request, _opts) do
      if before_deliver = Process.get(:stub_before_deliver), do: before_deliver.(request)
      Process.put(:stub_requests, [request | Process.get(:stub_requests, [])])
      Process.get(:stub_result) || Result.delivered(external_correlation_id: "ts-1")
    end

    @impl true
    def test(request, opts), do: deliver(request, opts)

    def requests, do: Enum.reverse(Process.get(:stub_requests, []))
    def answer_with(result), do: Process.put(:stub_result, result)
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    Process.delete(:stub_requests)
    Process.delete(:stub_result)
    Process.delete(:stub_before_deliver)

    {:ok, actor: SystemActor.system(:notification_delivery_test)}
  end

  describe "a delivered result" do
    test "records :sent with the provider handle", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      delivery = reload!(id, actor)
      assert delivery.state == :sent
      assert delivery.attempt_count == 1
      assert delivery.external_correlation_id == "ts-1"
      assert is_nil(delivery.next_attempt_at)
      assert delivery.payload_format == :json
      assert delivery.rendered_payload_digest
      assert delivery.finished_at
    end

    test "hands the transport a rendered payload and no unresolved secrets", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert [request] = StubTransport.requests()
      assert request.delivery_id == id
      assert request.payload_format == :json
      assert request.attempt == 1
      assert is_map(request.payload)
      # Transports read ALREADY-RESOLVED secrets; resolution is the dispatcher's
      # job, which is what keeps every transport test async and DB-free.
      assert request.secrets == %{}
    end

    test "claims the delivery before the transport can make an external side effect", %{
      actor: actor
    } do
      %{id: id, now: now} = planned!(actor)

      Process.put(:stub_before_deliver, fn request ->
        claimed = reload!(request.delivery_id, actor)
        assert claimed.state == :dispatching
        assert claimed.started_at
      end)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)
    end

    test "a second call does not send again", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert {:ok, :sent} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      # The Oban Iron Law: a worker must be safe to re-run against the same row.
      assert length(StubTransport.requests()) == 1
      assert reload!(id, actor).attempt_count == 1
    end

    test "a late close-out enqueue failure never rolls back an externally successful send", %{
      actor: actor
    } do
      %{id: id, now: now, alert: alert} = planned!(actor)

      alert
      |> Ash.Changeset.for_update(:resolve, %{}, actor: actor)
      |> Ash.update!(actor: actor)

      failing_opts = [
        actor: actor,
        now: now,
        transport: StubTransport,
        enqueue_routing: fn _alert_id, :resolve -> {:error, :queue_down} end,
        route_resolution: fn _alert_id, :resolve, _opts -> {:error, :database_down} end
      ]

      assert {:error,
              {:sent_but_resolution_unrouted,
               {:resolution_enqueue_failed, :queue_down,
                {:synchronous_resolution_failed, :database_down}}}} =
               Dispatcher.deliver(id, failing_opts)

      assert reload!(id, actor).state == :sent
      assert length(StubTransport.requests()) == 1

      # A duplicate job retries only the close-out repair. It never contacts
      # the destination again after the provider already accepted the page.
      assert {:error, {:sent_but_resolution_unrouted, _reason}} =
               Dispatcher.deliver(id, failing_opts)

      assert length(StubTransport.requests()) == 1
      assert reload!(id, actor).attempt_count == 1
    end
  end

  describe "not-before scheduling" do
    test "a pending delivery is not contacted before next_attempt_at", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)
      future = DateTime.add(now, 30, :second)
      delivery = reload!(id, actor)

      delivery
      |> Ash.Changeset.for_update(
        :record_group_member,
        %{alert_snapshot: delivery.alert_snapshot, next_attempt_at: future},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      assert {:retry, retry_at} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert DateTime.compare(retry_at, future) == :eq
      assert StubTransport.requests() == []
      assert reload!(id, actor).attempt_count == 0
    end
  end

  describe "a retryable result" do
    test "keeps the delivery :pending and schedules the next attempt", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)
      StubTransport.answer_with(Result.retryable_failure("http_503"))

      assert {:retry, at} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      delivery = reload!(id, actor)
      # C7: a retry-eligible delivery does NOT pass through :failed and come
      # back. `:failed` is terminal, and `read :retry_due` selects `:pending`.
      assert delivery.state == :pending
      assert delivery.attempt_count == 1
      assert delivery.error_class == "http_503"
      assert DateTime.after?(delivery.next_attempt_at, now)
      assert DateTime.after?(at, now)
    end

    test "honours a provider retry hint as a floor", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)
      StubTransport.answer_with(Result.retryable_failure("http_429", retry_after_ms: 600_000))

      assert {:retry, at} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert DateTime.diff(at, now, :second) >= 600
    end

    test "exhausting the attempt budget is terminal", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, max_attempts: 1)
      StubTransport.answer_with(Result.retryable_failure("http_503"))

      assert {:error, {:delivery_failed, "http_503"}} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      delivery = reload!(id, actor)
      assert delivery.state == :failed
      assert is_nil(delivery.next_attempt_at)
    end

    test "a permanent failure is terminal on the first attempt", %{actor: actor} do
      %{id: id, now: now} = planned!(actor)
      StubTransport.answer_with(Result.permanent_failure("http_400"))

      assert {:error, {:delivery_failed, "http_400"}} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      # A 400 will never be accepted; spending five attempts on it is how a
      # channel's whole budget disappears against one malformed payload.
      assert reload!(id, actor).state == :failed
    end
  end

  describe "suppression re-evaluated at dispatch" do
    test "a channel disabled after routing withholds the delivery", %{actor: actor} do
      %{id: id, now: now, channel: channel} = planned!(actor)

      channel
      |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
      |> Ash.update!(actor: actor)

      assert {:ok, :suppressed} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      delivery = reload!(id, actor)
      assert delivery.state == :suppressed
      assert delivery.suppression_reason == :channel_disabled
      # Design D5 prohibits silent drops: the withheld dispatch is recorded, and
      # the transport is never reached.
      assert StubTransport.requests() == []
    end

    test "an already-suppressed delivery answers from its own state", %{actor: actor} do
      %{id: id, now: now, channel: channel} = planned!(actor)

      channel
      |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
      |> Ash.update!(actor: actor)

      assert {:ok, :suppressed} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert {:ok, :suppressed} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)
    end
  end

  describe "the rate limiter" do
    test "an over-budget dispatch reschedules without burning an attempt", %{actor: actor} do
      %{id: id, now: now, channel: channel} = planned!(actor, rate_limit_per_minute: 1)
      on_exit(fn -> RateLimiter.reset(channel.id) end)

      assert RateLimiter.check_and_consume(channel.id, 1, now) == :ok

      assert {:retry, at} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert DateTime.after?(at, now)

      delivery = reload!(id, actor)
      # A rate limit is not a failed attempt. Burning `max_attempts` on a busy
      # channel would fail deliveries the destination never even saw.
      assert delivery.state == :pending
      assert delivery.attempt_count == 0
      assert StubTransport.requests() == []
    end

    test "the row stays visible to the retry scan while rate limited", %{actor: actor} do
      %{id: id, now: now, channel: channel} = planned!(actor, rate_limit_per_minute: 1)
      on_exit(fn -> RateLimiter.reset(channel.id) end)

      assert RateLimiter.check_and_consume(channel.id, 1, now) == :ok

      assert {:retry, _at} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      # No write happened, so durability rests entirely on the `next_attempt_at`
      # routing stamped. If the Oban job is lost here, the scan still has it.
      assert %{retry: retry_ids} = Dispatcher.due(now, actor: actor, limit: 50)
      assert id in retry_ids
    end
  end

  describe "failover" do
    test "a terminal failure hops once to the fallback channel", %{actor: actor} do
      fallback = create_channel!(actor, [])
      %{id: id, now: now, alert: alert} = planned!(actor, fallback_channel_id: fallback.id)

      StubTransport.answer_with(Result.permanent_failure("http_400"))

      assert {:error, {:delivery_failed, _class}} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert [successor] =
               NotificationDelivery
               |> Ash.Query.filter(originating_delivery_id == ^id)
               |> Ash.read!(actor: actor)

      assert successor.channel_id == fallback.id
      assert successor.state == :pending
      assert successor.alert_id == alert.id
      assert successor.alert_snapshot["id"] == alert.id
    end

    test "the successor never fails over again", %{actor: actor} do
      fallback = create_channel!(actor, fallback_channel_id: nil)
      %{id: id, now: now} = planned!(actor, fallback_channel_id: fallback.id)

      StubTransport.answer_with(Result.permanent_failure("http_400"))

      assert {:error, _reason} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert [successor] =
               NotificationDelivery
               |> Ash.Query.filter(originating_delivery_id == ^id)
               |> Ash.read!(actor: actor)

      assert {:error, _reason} =
               Dispatcher.deliver(successor.id, actor: actor, now: now, transport: StubTransport)

      # Exactly one hop (design D4). Without the bound, a fallback chain that
      # loops back would page forever.
      assert NotificationDelivery
             |> Ash.Query.filter(originating_delivery_id == ^successor.id)
             |> Ash.read!(actor: actor) == []
    end

    test "a fail_closed channel never fails over", %{actor: actor} do
      fallback = create_channel!(actor, [])

      %{id: id, now: now} =
        planned!(actor, fallback_channel_id: fallback.id, fail_closed: true)

      StubTransport.answer_with(Result.permanent_failure("http_400"))

      assert {:error, _reason} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      assert NotificationDelivery
             |> Ash.Query.filter(originating_delivery_id == ^id)
             |> Ash.read!(actor: actor) == []
    end

    test "the failed origin and successor are one atomic write", %{actor: actor} do
      fallback = create_channel!(actor, [])
      %{id: id, now: now} = planned!(actor, fallback_channel_id: fallback.id)

      StubTransport.answer_with(Result.permanent_failure("http_400"))

      fail_create = fn :record_dispatch, _attrs, _actor -> {:error, :write_failed} end

      assert {:error, {:failover_persistence_failed, :write_failed}} =
               Dispatcher.deliver(id,
                 actor: actor,
                 now: now,
                 transport: StubTransport,
                 create_failover_delivery: fail_create
               )

      # The pre-fix order committed :failed and then discarded the successor
      # write error, making the notification permanently unreachable. Rolling
      # both writes back leaves this transport attempt recoverable by the
      # dispatching-stall scan.
      dispatching = reload!(id, actor)
      assert dispatching.state == :dispatching
      assert %DateTime{} = dispatching.started_at

      assert %{settled: settled_ids} =
               Dispatcher.reconcile(DateTime.add(dispatching.started_at, 301, :second),
                 actor: actor,
                 limit: 50,
                 stall_seconds: 300
               )

      assert id in settled_ids
      assert reload!(id, actor).state == :pending

      assert NotificationDelivery
             |> Ash.Query.filter(originating_delivery_id == ^id)
             |> Ash.read!(actor: actor) == []
    end
  end

  describe "unprocessable deliveries" do
    test "an unknown delivery id is an error", %{actor: actor} do
      assert {:error, :delivery_not_found} =
               Dispatcher.deliver(Ash.UUIDv7.generate(), actor: actor)
    end

    test "a deleted channel terminalizes its pending delivery", %{actor: actor} do
      %{id: id, now: now, channel: channel} = planned!(actor)

      Ash.destroy!(channel, actor: actor)

      assert {:error, {:delivery_failed, "channel_not_found"}} =
               Dispatcher.deliver(id, actor: actor, now: now, transport: StubTransport)

      delivery = reload!(id, actor)
      assert delivery.state == :failed
      assert delivery.error_class == "channel_not_found"
      assert StubTransport.requests() == []

      assert %{retry: retry_ids} =
               Dispatcher.due(DateTime.add(now, 1, :day), actor: actor, limit: 50)

      refute id in retry_ids
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp planned!(actor, channel_opts \\ []) do
    channel = create_channel!(actor, channel_opts)
    policy = create_policy!(actor)
    step = create_step!(actor, policy)
    attach!(actor, step, channel)
    create_route!(actor, policy)

    alert = create_alert!(actor)
    now = DateTime.add(alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

    %{id: id, alert: alert, channel: channel, now: now}
  end

  defp reload!(id, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: id})
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

  # Providers are born `:draft`, and `Suppression` withholds a dispatch to a
  # channel whose provider is not `:active` with `:channel_disabled`. Activating
  # is therefore part of a usable fixture, not boilerplate: without it every
  # test here would assert against suppression rather than against delivery.
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
