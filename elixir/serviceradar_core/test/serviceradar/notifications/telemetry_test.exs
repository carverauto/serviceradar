defmodule ServiceRadar.Notifications.TelemetryTest do
  @moduledoc """
  The notification telemetry contract, asserted without a database.

  Two properties matter more than "an event was emitted":

    1. **Metadata carries identifiers and classifications only.** A telemetry
       handler ships metadata to Prometheus label sets, log lines, and traces
       without further review, so a payload, a rendered body, or a resolved
       secret that reaches metadata reaches all three at once. The emitter is
       therefore total over its input - a caller that hands it a map where a
       classification belongs gets `nil`, not a stringified map.
    2. **The label sets in `metrics/0` are bounded.** `alert_id` and
       `delivery_id` are deliberately in metadata and deliberately not tags; a
       per-alert label is unbounded cardinality and would take a Prometheus
       instance down long before anyone noticed the dashboard was wrong.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Telemetry

  # A named capture rather than an anonymous function: `:telemetry.attach/4` logs
  # an advisory line for every local-function handler, which is 26 lines of noise
  # in a suite this size.
  @doc false
  def forward(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  setup context do
    handler = "notifications-telemetry-test-#{inspect(context.test)}"

    :telemetry.attach_many(handler, Telemetry.events(), &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)

    :ok
  end

  describe "routed/1" do
    test "carries the plan sizes as measurements and the alert as metadata" do
      Telemetry.routed(%{
        alert_id: "alert-1",
        lifecycle_reason: :fire,
        matched_routes: 2,
        planned: 3,
        suppressed: 1
      })

      assert_receive {:telemetry, [:serviceradar, :notifications, :routed], measurements,
                      metadata}

      assert measurements == %{count: 1, planned: 3, suppressed: 1}
      assert metadata == %{alert_id: "alert-1", lifecycle_reason: :fire, matched_routes: 2}
    end

    test "an absent count is zero rather than nil" do
      Telemetry.routed(%{alert_id: "alert-1", lifecycle_reason: :fire})

      assert_receive {:telemetry, [:serviceradar, :notifications, :routed], measurements,
                      metadata}

      assert measurements == %{count: 1, planned: 0, suppressed: 0}
      assert metadata.matched_routes == 0
    end
  end

  describe "suppressed/1" do
    test "names the reason and the phase the decision was made in" do
      Telemetry.suppressed(%{
        alert_id: "alert-1",
        delivery_id: "delivery-1",
        channel_id: "channel-1",
        suppression_reason: :silence,
        occurrence_count: 7,
        phase: :dispatch
      })

      assert_receive {:telemetry, [:serviceradar, :notifications, :suppressed], measurements,
                      metadata}

      assert measurements == %{count: 1, occurrence_count: 7}
      assert metadata.suppression_reason == :silence
      assert metadata.phase == :dispatch
      assert metadata.channel_id == "channel-1"
    end

    test "an unrouted decision carries no policy, step, or channel" do
      # The `:no_matching_route` row has NULL in all three positions. The event
      # has to survive that rather than assuming a channel is always present.
      Telemetry.suppressed(%{
        alert_id: "alert-1",
        delivery_id: "delivery-1",
        suppression_reason: :no_matching_route,
        phase: :routing
      })

      assert_receive {:telemetry, [:serviceradar, :notifications, :suppressed], measurements,
                      metadata}

      assert measurements == %{count: 1, occurrence_count: 1}
      assert is_nil(metadata.channel_id)
      assert is_nil(metadata.policy_id)
      assert is_nil(metadata.step_number)
    end
  end

  describe "dispatched/1, sent/1, failed/1, retried/1" do
    test "the dispatch-attempted signal carries the channel, provider, and route" do
      Telemetry.dispatched(dispatch_fields())

      assert_receive {:telemetry, [:serviceradar, :notifications, :dispatched], measurements,
                      metadata}

      assert measurements == %{count: 1, attempt: 2}
      assert metadata.channel_id == "channel-1"
      assert metadata.provider_key == "slack"
      assert metadata.provider_type == :native
      assert metadata.execution_route == :control_plane
      assert metadata.is_test == false
    end

    test "the dispatch-succeeded signal carries end-to-end latency" do
      Telemetry.sent(Map.put(dispatch_fields(), :dispatch_latency_ms, 4_200))

      assert_receive {:telemetry, [:serviceradar, :notifications, :sent], measurements, _metadata}

      assert measurements == %{count: 1, attempt: 2, dispatch_latency_ms: 4_200}
    end

    test "an unmeasurable latency is omitted rather than sent as zero" do
      # A delivery whose alert snapshot has no fire time cannot produce a
      # latency. Emitting a zero would report an instant page.
      Telemetry.sent(Map.put(dispatch_fields(), :dispatch_latency_ms, nil))

      assert_receive {:telemetry, [:serviceradar, :notifications, :sent], measurements, _metadata}

      refute Map.has_key?(measurements, :dispatch_latency_ms)
    end

    test "the dispatch-failed signal carries the error class" do
      Telemetry.failed(Map.put(dispatch_fields(), :error_class, "http_500"))

      assert_receive {:telemetry, [:serviceradar, :notifications, :failed], measurements,
                      metadata}

      assert measurements == %{count: 1, attempt: 2}
      assert metadata.error_class == "http_500"
    end

    test "a retry is a different series from a failure" do
      # Design D4: a delivery that is retrying is still owed. Counting it as a
      # failure overstates the error rate by the whole attempt budget.
      dispatch_fields()
      |> Map.put(:error_class, "http_429")
      |> Map.put(:delay_ms, 30_000)
      |> Telemetry.retried()

      assert_receive {:telemetry, [:serviceradar, :notifications, :retried], measurements,
                      metadata}

      assert measurements == %{count: 1, attempt: 2, delay_ms: 30_000}
      assert metadata.error_class == "http_429"

      refute_received {:telemetry, [:serviceradar, :notifications, :failed], _measurements,
                       _metadata}
    end
  end

  describe "failed_over/1 and escalated/1" do
    test "a failover names both ends of the hop" do
      Telemetry.failed_over(%{
        alert_id: "alert-1",
        delivery_id: "delivery-1",
        successor_delivery_id: "delivery-2",
        channel_id: "channel-1",
        fallback_channel_id: "channel-2",
        step_number: 1
      })

      assert_receive {:telemetry, [:serviceradar, :notifications, :failed_over], measurements,
                      metadata}

      assert measurements == %{count: 1}
      assert metadata.delivery_id == "delivery-1"
      assert metadata.successor_delivery_id == "delivery-2"
      assert metadata.fallback_channel_id == "channel-2"
    end

    test "an escalation carries the step it reached" do
      Telemetry.escalated(%{
        alert_id: "alert-1",
        delivery_id: "delivery-1",
        policy_id: "policy-1",
        channel_id: "channel-1",
        step_number: 3
      })

      assert_receive {:telemetry, [:serviceradar, :notifications, :escalated], measurements,
                      metadata}

      assert measurements == %{count: 1, step_number: 3}
      assert metadata.step_number == 3
      assert metadata.policy_id == "policy-1"
    end
  end

  describe "acknowledged/1" do
    test "carries acknowledgement latency and MTTR" do
      Telemetry.acknowledged(%{
        alert_id: "alert-1",
        delivery_id: "delivery-1",
        action: :resolve,
        source: :action_link,
        actor_kind: :external_principal,
        status: :applied,
        ack_latency_ms: 90_000,
        resolution_latency_ms: 600_000
      })

      assert_receive {:telemetry, [:serviceradar, :notifications, :acknowledged], measurements,
                      metadata}

      assert measurements == %{
               count: 1,
               ack_latency_ms: 90_000,
               resolution_latency_ms: 600_000
             }

      assert metadata.action == :resolve
      assert metadata.status == :applied
    end

    test "a replay is still counted but contributes no latency" do
      Telemetry.acknowledged(%{
        alert_id: "alert-1",
        delivery_id: "delivery-1",
        action: :acknowledge,
        source: :action_link,
        actor_kind: :external_principal,
        status: :replayed
      })

      assert_receive {:telemetry, [:serviceradar, :notifications, :acknowledged], measurements,
                      metadata}

      assert measurements == %{count: 1}
      assert metadata.status == :replayed
    end
  end

  describe "metadata carries no payload, body, or secret" do
    test "the metadata key set is fixed and does not echo unknown input" do
      # The dispatcher builds these maps from delivery rows. If a future field
      # were added to that map without being added here, this asserts it does
      # NOT ride along into telemetry unreviewed.
      Telemetry.dispatched(
        Map.merge(dispatch_fields(), %{
          payload: %{"text" => "Device down at 10.0.0.1"},
          body: "Device down",
          subject: "CRITICAL",
          secrets: %{"webhook_url" => "https://hooks.example.com/T000/B000/XXXX"},
          config: %{"url" => "https://hooks.example.com"}
        })
      )

      assert_receive {:telemetry, [:serviceradar, :notifications, :dispatched], _measurements,
                      metadata}

      assert Enum.sort(Map.keys(metadata)) == [
               :alert_id,
               :channel_id,
               :delivery_id,
               :execution_route,
               :is_test,
               :policy_id,
               :provider_key,
               :provider_type,
               :route_id,
               :step_number
             ]
    end

    test "a classification handed a map becomes nil rather than an inspected struct" do
      # `inspect/1` on a config map is exactly how a secret leaks into a label.
      Telemetry.failed(
        Map.merge(dispatch_fields(), %{
          provider_key: %{"token" => "xoxb-secret"},
          error_class: %{"detail" => ~s(500: {"error":"token xoxb-secret"})}
        })
      )

      assert_receive {:telemetry, [:serviceradar, :notifications, :failed], _measurements,
                      metadata}

      assert is_nil(metadata.provider_key)
      assert is_nil(metadata.error_class)
    end

    test "an identifier that is not a plain id is dropped" do
      Telemetry.dispatched(
        Map.put(dispatch_fields(), :alert_id, %Ash.NotLoaded{type: :relationship})
      )

      assert_receive {:telemetry, [:serviceradar, :notifications, :dispatched], _measurements,
                      metadata}

      assert is_nil(metadata.alert_id)
    end

    test "no emitted metadata value is a map or a struct" do
      for fields <- [
            dispatch_fields(),
            Map.put(dispatch_fields(), :suppression_reason, :silence),
            Map.put(dispatch_fields(), :error_class, "http_500")
          ],
          emitter <- [
            &Telemetry.dispatched/1,
            &Telemetry.sent/1,
            &Telemetry.failed/1,
            &Telemetry.retried/1,
            &Telemetry.suppressed/1
          ] do
        emitter.(fields)

        assert_receive {:telemetry, _event, _measurements, metadata}

        for {key, value} <- metadata do
          refute is_map(value), "#{key} carried a map into telemetry metadata"
        end
      end
    end
  end

  describe "latency_ms/2" do
    test "measures forward in milliseconds" do
      from = ~U[2026-08-09 12:00:00.000000Z]
      to = ~U[2026-08-09 12:00:04.500000Z]

      assert Telemetry.latency_ms(from, to) == 4_500
    end

    test "clamps a backwards interval to zero" do
      # Two nodes, two clocks. A negative sample in a duration histogram is
      # worse than a missing one.
      from = ~U[2026-08-09 12:00:04Z]
      to = ~U[2026-08-09 12:00:00Z]

      assert Telemetry.latency_ms(from, to) == 0
    end

    test "a missing endpoint yields no measurement" do
      assert is_nil(Telemetry.latency_ms(nil, ~U[2026-08-09 12:00:00Z]))
      assert is_nil(Telemetry.latency_ms(~U[2026-08-09 12:00:00Z], nil))
      assert is_nil(Telemetry.latency_ms(nil, nil))
    end
  end

  describe "metrics/0" do
    test "every metric attaches to an event this module actually emits" do
      events = MapSet.new(Telemetry.events())

      for metric <- Telemetry.metrics() do
        assert MapSet.member?(events, metric.event_name),
               "#{Enum.join(metric.name, ".")} listens for an event nothing emits"
      end
    end

    test "no metric tags on an unbounded identifier" do
      for metric <- Telemetry.metrics() do
        refute :alert_id in metric.tags,
               "#{Enum.join(metric.name, ".")} would mint one label set per alert"

        refute :delivery_id in metric.tags,
               "#{Enum.join(metric.name, ".")} would mint one label set per delivery"
      end
    end

    test "metric names are unique" do
      names = Enum.map(Telemetry.metrics(), & &1.name)

      assert names == Enum.uniq(names)
    end

    test "covers the service level indicators the spec names" do
      names = Enum.map(Telemetry.metrics(), &Enum.join(&1.name, "."))

      for required <- [
            "serviceradar.notifications.dispatch.attempted.count",
            "serviceradar.notifications.dispatch.succeeded.count",
            "serviceradar.notifications.dispatch.failed.count",
            "serviceradar.notifications.dispatch.latency",
            "serviceradar.notifications.suppressed.count",
            "serviceradar.notifications.acknowledgement.latency",
            "serviceradar.notifications.resolution.latency",
            "serviceradar.notifications.retry.count",
            "serviceradar.notifications.failover.count",
            "serviceradar.notifications.escalation.count"
          ] do
        assert required in names
      end
    end

    test "retry, failover, and escalation are three separate series" do
      # D4 again, this time at the reporter. One counter that all three
      # incremented could not answer "did the ladder fire?".
      by_name =
        Map.new(Telemetry.metrics(), fn metric -> {Enum.join(metric.name, "."), metric} end)

      assert by_name["serviceradar.notifications.retry.count"].event_name !=
               by_name["serviceradar.notifications.failover.count"].event_name

      assert by_name["serviceradar.notifications.failover.count"].event_name !=
               by_name["serviceradar.notifications.escalation.count"].event_name
    end

    test "every declared tag resolves against the emitted metadata" do
      # A reporter drops or raises on a sample whose metadata is missing a
      # declared tag, so the tag_values functions must be total over what the
      # emitters actually produce.
      Telemetry.dispatched(%{})
      assert_receive {:telemetry, _dispatched_event, _dispatched, dispatch_metadata}

      Telemetry.suppressed(%{})
      assert_receive {:telemetry, _suppressed_event, _suppressed, suppression_metadata}

      Telemetry.acknowledged(%{})
      assert_receive {:telemetry, _ack_event, _ack, ack_metadata}

      Telemetry.failed_over(%{})
      assert_receive {:telemetry, _failover_event, _failover, failover_metadata}

      Telemetry.routed(%{})
      assert_receive {:telemetry, _routed_event, _routed, routed_metadata}

      metadata_by_event =
        Map.new(
          [
            {[:serviceradar, :notifications, :dispatched], dispatch_metadata},
            {[:serviceradar, :notifications, :sent], dispatch_metadata},
            {[:serviceradar, :notifications, :failed], dispatch_metadata},
            {[:serviceradar, :notifications, :retried], dispatch_metadata},
            {[:serviceradar, :notifications, :suppressed], suppression_metadata},
            {[:serviceradar, :notifications, :acknowledged], ack_metadata},
            {[:serviceradar, :notifications, :failed_over], failover_metadata},
            {[:serviceradar, :notifications, :escalated], failover_metadata},
            {[:serviceradar, :notifications, :routed], routed_metadata}
          ],
          & &1
        )

      for metric <- Telemetry.metrics() do
        metadata = Map.fetch!(metadata_by_event, metric.event_name)
        values = metric.tag_values.(metadata)

        for tag <- metric.tags do
          assert Map.has_key?(values, tag),
                 "#{Enum.join(metric.name, ".")} declares #{tag} but tag_values does not supply it"

          assert is_binary(Map.fetch!(values, tag)),
                 "#{Enum.join(metric.name, ".")} left #{tag} unstringified"
        end
      end
    end
  end

  defp dispatch_fields do
    %{
      alert_id: "alert-1",
      delivery_id: "delivery-1",
      channel_id: "channel-1",
      policy_id: "policy-1",
      route_id: "route-1",
      step_number: 1,
      attempt: 2,
      provider_key: "slack",
      provider_type: :native,
      execution_route: :control_plane,
      is_test: false
    }
  end
end
