defmodule ServiceRadar.Notifications.Telemetry do
  @moduledoc """
  Every dispatch decision and outcome, as a `:telemetry` event.

  Nine events, all under the repo's `[:serviceradar, <component>, <action>]`
  naming convention with `:notifications` as the component:

  | Event | Emitted when |
  | --- | --- |
  | `[:serviceradar, :notifications, :routed]` | `Dispatcher.route/3` finished planning an alert |
  | `[:serviceradar, :notifications, :suppressed]` | a notification was withheld, at routing time or re-evaluated at dispatch |
  | `[:serviceradar, :notifications, :dispatched]` | a transport attempt was made (dispatch-attempted) |
  | `[:serviceradar, :notifications, :sent]` | the destination accepted it (dispatch-succeeded) |
  | `[:serviceradar, :notifications, :failed]` | the delivery reached the terminal `:failed` state (dispatch-failed) |
  | `[:serviceradar, :notifications, :retried]` | a retryable failure was scheduled for another attempt |
  | `[:serviceradar, :notifications, :failed_over]` | a failed delivery hopped to its fallback channel |
  | `[:serviceradar, :notifications, :escalated]` | an escalation rung above step 1 was planned |
  | `[:serviceradar, :notifications, :acknowledged]` | an inbound acknowledge/snooze/resolve was accepted |

  `:retried`, `:failed_over`, and `:escalated` are three separate series on
  purpose. Retry, failover, and escalation are three mechanisms and conflating
  them is the classic notification-platform error (design D4); a single
  "notification retried" counter that all three increment cannot answer "did the
  ladder work?" or "is this channel flapping?".

  ## Measurements versus metadata

  Measurements are numbers a reporter aggregates: `count`, an attempt number, a
  latency in milliseconds. Metadata is **identifiers and classifications only**.

  A metadata field is never a payload, a rendered subject or body, a resolved
  secret, an alert title, or an operator's free text. The dispatcher already logs
  that way deliberately and the same rule holds here, because a telemetry handler
  is the one place a payload leaks without anyone reviewing a log line: reporters
  ship metadata to Prometheus label sets, log lines, and traces indiscriminately.
  The spec states it outright - "Telemetry payloads SHALL contain no secret
  material and no unredacted alert content".

  Cardinality follows from the same split. `alert_id` and `delivery_id` are in
  metadata because a log or trace handler needs to correlate one page with one
  incident, but they are **not** tags on any metric in `metrics/0` - a per-alert
  label set is unbounded. The tagged fields are the bounded classifications:
  `channel_id`, `provider_key`, `provider_type`, `execution_route`,
  `error_class`, `suppression_reason`, `action`, `source`, `is_test`.

  ## Why `:telemetry` and not a JetStream subject

  The repo hard rule is that a **metric destined for storage** publishes to a
  JetStream subject and is persisted by the `event_writer` consumer; nothing
  writes a metric straight to the database. Nothing here is such a metric. These
  are in-process `:telemetry` events, consumed by whichever reporter the runtime
  attaches - the same mechanism `ServiceRadar.Telemetry`,
  `ServiceRadar.Actors.Telemetry`, and `ServiceRadarAgentGateway.Telemetry` use.
  No row is written, no subject is published, and no NATS per-CN allowlist in
  `helm/serviceradar/templates/nats.yaml` needs a new namespace. If a later phase
  wants these persisted as a time series, that is a JetStream publisher attached
  to these events, not a change to the emission sites.

  ## The service level indicators

  `metrics/0` returns `Telemetry.Metrics` definitions for the SLIs the spec
  names, ready for a Prometheus reporter or LiveDashboard:

    * dispatch attempted / succeeded / failed counters, tagged per channel, which
      is what makes a **per-channel error rate** a query rather than a new series;
    * suppression counter tagged by `suppression_reason`, likewise for the
      **per-channel suppression rate** broken down by reason;
    * **end-to-end dispatch latency** from alert fire time to the first `:sent`
      delivery;
    * **acknowledgement latency** from that first `:sent` to the first accepted
      acknowledgement;
    * **MTTR** as the resolution latency from alert fire time to an accepted
      `:resolve`;
    * retry, failover, and escalation counters as separate series.

  See `openspec/changes/add-notification-platform/specs/notification-platform/spec.md`,
  "Notification telemetry and service level indicators".
  """

  @prefix [:serviceradar, :notifications]

  @routed @prefix ++ [:routed]
  @suppressed @prefix ++ [:suppressed]
  @dispatched @prefix ++ [:dispatched]
  @sent @prefix ++ [:sent]
  @failed @prefix ++ [:failed]
  @retried @prefix ++ [:retried]
  @failed_over @prefix ++ [:failed_over]
  @escalated @prefix ++ [:escalated]
  @acknowledged @prefix ++ [:acknowledged]

  @latency_buckets_ms [
    100,
    500,
    1_000,
    5_000,
    15_000,
    30_000,
    60_000,
    300_000,
    900_000,
    3_600_000
  ]

  @doc "The `[:serviceradar, :notifications]` event prefix."
  @spec prefix() :: [atom()]
  def prefix, do: @prefix

  @doc "Every event name this module emits, for `:telemetry.attach_many/4`."
  @spec events() :: [[atom()]]
  def events do
    [
      @routed,
      @suppressed,
      @dispatched,
      @sent,
      @failed,
      @retried,
      @failed_over,
      @escalated,
      @acknowledged
    ]
  end

  # --- emission -------------------------------------------------------------

  @doc """
  One completed routing decision.

  `planned` and `suppressed` are the delivery counts the decision produced;
  `matched_routes` is how many enabled routes the alert matched, so zero
  distinguishes "unrouted" from "routed and then withheld".
  """
  @spec routed(map()) :: :ok
  def routed(fields) when is_map(fields) do
    emit(
      @routed,
      %{
        count: 1,
        planned: integer(fields[:planned], 0),
        suppressed: integer(fields[:suppressed], 0)
      },
      %{
        alert_id: id(fields[:alert_id]),
        lifecycle_reason: classification(fields[:lifecycle_reason]),
        matched_routes: integer(fields[:matched_routes], 0)
      }
    )
  end

  @doc """
  One withheld notification.

  `phase` is `:routing` when the decision was made while planning and
  `:dispatch` when re-evaluation withheld an already-queued delivery; the two
  mean different things to an operator and a single counter cannot tell them
  apart.
  """
  @spec suppressed(map()) :: :ok
  def suppressed(fields) when is_map(fields) do
    emit(
      @suppressed,
      %{count: 1, occurrence_count: integer(fields[:occurrence_count], 1)},
      %{
        alert_id: id(fields[:alert_id]),
        delivery_id: id(fields[:delivery_id]),
        channel_id: id(fields[:channel_id]),
        policy_id: id(fields[:policy_id]),
        step_number: fields[:step_number],
        provider_key: classification(fields[:provider_key]),
        provider_type: classification(fields[:provider_type]),
        suppression_reason: classification(fields[:suppression_reason]),
        phase: classification(fields[:phase])
      }
    )
  end

  @doc "A transport attempt was made. The dispatch-attempted signal."
  @spec dispatched(map()) :: :ok
  def dispatched(fields) when is_map(fields) do
    emit(
      @dispatched,
      %{count: 1, attempt: integer(fields[:attempt], 1)},
      dispatch_metadata(fields)
    )
  end

  @doc """
  The destination accepted the notification. The dispatch-succeeded signal.

  `dispatch_latency_ms` - alert fire time to this first `:sent` delivery - is
  omitted rather than sent as `nil` when the fire time is unknown, so a
  distribution never records a zero it did not measure.
  """
  @spec sent(map()) :: :ok
  def sent(fields) when is_map(fields) do
    measurements =
      put_latency(
        %{count: 1, attempt: integer(fields[:attempt], 1)},
        :dispatch_latency_ms,
        fields[:dispatch_latency_ms]
      )

    emit(@sent, measurements, dispatch_metadata(fields))
  end

  @doc """
  The delivery reached the terminal `:failed` state. The dispatch-failed signal.

  `error_class` is the transport's classification string - `"http_500"`,
  `"transport_unavailable"` - never the error message, which can quote a
  destination's response body.
  """
  @spec failed(map()) :: :ok
  def failed(fields) when is_map(fields) do
    metadata =
      fields
      |> dispatch_metadata()
      |> Map.put(:error_class, classification(fields[:error_class]))

    emit(@failed, %{count: 1, attempt: integer(fields[:attempt], 1)}, metadata)
  end

  @doc """
  A retryable failure was handed back to the scheduler.

  Deliberately not the same series as `failed/1`: a delivery that is retrying is
  still owed, and counting it as a failure overstates the error rate by the
  attempt budget.
  """
  @spec retried(map()) :: :ok
  def retried(fields) when is_map(fields) do
    metadata =
      fields
      |> dispatch_metadata()
      |> Map.put(:error_class, classification(fields[:error_class]))

    measurements =
      put_latency(
        %{count: 1, attempt: integer(fields[:attempt], 1)},
        :delay_ms,
        fields[:delay_ms]
      )

    emit(@retried, measurements, metadata)
  end

  @doc "A failed delivery hopped once to its fallback channel."
  @spec failed_over(map()) :: :ok
  def failed_over(fields) when is_map(fields) do
    emit(
      @failed_over,
      %{count: 1},
      %{
        alert_id: id(fields[:alert_id]),
        delivery_id: id(fields[:delivery_id]),
        successor_delivery_id: id(fields[:successor_delivery_id]),
        channel_id: id(fields[:channel_id]),
        fallback_channel_id: id(fields[:fallback_channel_id]),
        step_number: fields[:step_number]
      }
    )
  end

  @doc """
  An escalation rung above step 1 was planned.

  Step 1 is the first notification, not an escalation, and counting it as one
  makes every paged alert look escalated.
  """
  @spec escalated(map()) :: :ok
  def escalated(fields) when is_map(fields) do
    emit(
      @escalated,
      %{count: 1, step_number: integer(fields[:step_number], 0)},
      %{
        alert_id: id(fields[:alert_id]),
        delivery_id: id(fields[:delivery_id]),
        policy_id: id(fields[:policy_id]),
        channel_id: id(fields[:channel_id]),
        step_number: fields[:step_number]
      }
    )
  end

  @doc """
  An inbound acknowledge, snooze, or resolve was accepted.

  `ack_latency_ms` measures from the first `:sent` delivery to this action and
  `resolution_latency_ms` - MTTR - from alert fire time to an accepted
  `:resolve`. Both are omitted when the originating instant is unknown.

  `status` distinguishes `:applied` from `:already_applied` and `:replayed`, so a
  double-clicked action link does not inflate the acknowledgement count or drag
  the latency distribution toward zero.
  """
  @spec acknowledged(map()) :: :ok
  def acknowledged(fields) when is_map(fields) do
    measurements =
      %{count: 1}
      |> put_latency(:ack_latency_ms, fields[:ack_latency_ms])
      |> put_latency(:resolution_latency_ms, fields[:resolution_latency_ms])

    emit(
      @acknowledged,
      measurements,
      %{
        alert_id: id(fields[:alert_id]),
        delivery_id: id(fields[:delivery_id]),
        action: classification(fields[:action]),
        source: classification(fields[:source]),
        actor_kind: classification(fields[:actor_kind]),
        status: classification(fields[:status])
      }
    )
  end

  @doc """
  Milliseconds between two instants, or `nil` when either is missing.

  Clamped at zero: a delivery whose `finished_at` was stamped by a node whose
  clock is behind the one that received the acknowledgement would otherwise
  contribute a negative latency, and a negative sample in a duration histogram is
  worse than a missing one.
  """
  @spec latency_ms(DateTime.t() | nil, DateTime.t() | nil) :: non_neg_integer() | nil
  def latency_ms(%DateTime{} = from, %DateTime{} = to) do
    to |> DateTime.diff(from, :millisecond) |> max(0)
  end

  def latency_ms(_from, _to), do: nil

  # --- metrics --------------------------------------------------------------

  @doc """
  `Telemetry.Metrics` definitions for the notification SLIs.

  Consumed by any reporter that wants them - the core-elx Prometheus reporter,
  LiveDashboard, a test. Tags are bounded classifications only; `alert_id` and
  `delivery_id` stay in metadata and out of every label set here.
  """
  @spec metrics() :: [struct()]
  def metrics do
    import Telemetry.Metrics

    [
      counter("serviceradar.notifications.routed.count",
        event_name: @routed,
        tags: [:lifecycle_reason],
        tag_values: &routing_tag_values/1,
        description: "Routing decisions completed"
      ),
      counter("serviceradar.notifications.suppressed.count",
        event_name: @suppressed,
        tags: [:suppression_reason, :phase, :channel_id],
        tag_values: &suppression_tag_values/1,
        description: "Notifications withheld, by reason - the per-channel suppression rate"
      ),
      counter("serviceradar.notifications.dispatch.attempted.count",
        event_name: @dispatched,
        tags: [:channel_id, :provider_key, :provider_type, :execution_route, :is_test],
        tag_values: &dispatch_tag_values/1,
        description: "Transport attempts made"
      ),
      counter("serviceradar.notifications.dispatch.succeeded.count",
        event_name: @sent,
        tags: [:channel_id, :provider_key, :provider_type, :execution_route, :is_test],
        tag_values: &dispatch_tag_values/1,
        description: "Transport attempts the destination accepted"
      ),
      counter("serviceradar.notifications.dispatch.failed.count",
        event_name: @failed,
        tags: [:channel_id, :provider_key, :provider_type, :execution_route, :error_class],
        tag_values: &failure_tag_values/1,
        description:
          "Deliveries that reached :failed - the numerator of the per-channel error rate"
      ),
      distribution("serviceradar.notifications.dispatch.latency",
        event_name: @sent,
        measurement: :dispatch_latency_ms,
        unit: :millisecond,
        tags: [:channel_id, :provider_key, :provider_type, :execution_route, :is_test],
        tag_values: &dispatch_tag_values/1,
        reporter_options: [buckets: @latency_buckets_ms],
        description: "Alert fire time to the first :sent delivery"
      ),
      counter("serviceradar.notifications.retry.count",
        event_name: @retried,
        tags: [:channel_id, :provider_key, :provider_type, :execution_route, :error_class],
        tag_values: &failure_tag_values/1,
        description:
          "Retryable failures rescheduled - never conflated with failover or escalation"
      ),
      counter("serviceradar.notifications.failover.count",
        event_name: @failed_over,
        tags: [:channel_id],
        tag_values: &failover_tag_values/1,
        description: "Failover hops taken to a fallback channel"
      ),
      counter("serviceradar.notifications.escalation.count",
        event_name: @escalated,
        tags: [:channel_id],
        tag_values: &failover_tag_values/1,
        description: "Escalation rungs above step 1 that were planned"
      ),
      counter("serviceradar.notifications.acknowledgement.count",
        event_name: @acknowledged,
        tags: [:action, :source, :actor_kind, :status],
        tag_values: &acknowledgement_tag_values/1,
        description: "Inbound actions accepted from a notification"
      ),
      distribution("serviceradar.notifications.acknowledgement.latency",
        event_name: @acknowledged,
        measurement: :ack_latency_ms,
        unit: :millisecond,
        tags: [:action, :source, :actor_kind, :status],
        tag_values: &acknowledgement_tag_values/1,
        reporter_options: [buckets: @latency_buckets_ms],
        description: "First :sent delivery to the first accepted acknowledgement"
      ),
      distribution("serviceradar.notifications.resolution.latency",
        event_name: @acknowledged,
        measurement: :resolution_latency_ms,
        unit: :millisecond,
        tags: [:action, :source, :actor_kind, :status],
        tag_values: &acknowledgement_tag_values/1,
        reporter_options: [buckets: @latency_buckets_ms],
        description: "MTTR: alert fire time to an accepted resolve"
      )
    ]
  end

  # --- tag values -----------------------------------------------------------

  # Every tag a reporter declares must be present in the metadata it is handed;
  # a missing key drops the sample on some reporters and raises on others. These
  # normalise to a string with an explicit default so neither happens.

  defp routing_tag_values(metadata) do
    %{lifecycle_reason: tag(metadata[:lifecycle_reason])}
  end

  defp suppression_tag_values(metadata) do
    %{
      suppression_reason: tag(metadata[:suppression_reason]),
      phase: tag(metadata[:phase]),
      channel_id: tag(metadata[:channel_id])
    }
  end

  defp dispatch_tag_values(metadata) do
    %{
      channel_id: tag(metadata[:channel_id]),
      provider_key: tag(metadata[:provider_key]),
      provider_type: tag(metadata[:provider_type]),
      execution_route: tag(metadata[:execution_route]),
      is_test: tag(metadata[:is_test])
    }
  end

  defp failure_tag_values(metadata) do
    %{
      channel_id: tag(metadata[:channel_id]),
      provider_key: tag(metadata[:provider_key]),
      provider_type: tag(metadata[:provider_type]),
      execution_route: tag(metadata[:execution_route]),
      error_class: tag(metadata[:error_class])
    }
  end

  defp failover_tag_values(metadata) do
    %{channel_id: tag(metadata[:channel_id])}
  end

  defp acknowledgement_tag_values(metadata) do
    %{
      action: tag(metadata[:action]),
      source: tag(metadata[:source]),
      actor_kind: tag(metadata[:actor_kind]),
      status: tag(metadata[:status])
    }
  end

  defp tag(nil), do: "unknown"
  defp tag(""), do: "unknown"
  defp tag(value) when is_binary(value), do: value
  defp tag(value) when is_atom(value), do: Atom.to_string(value)
  defp tag(value), do: to_string(value)

  # --- helpers --------------------------------------------------------------

  defp dispatch_metadata(fields) do
    %{
      alert_id: id(fields[:alert_id]),
      delivery_id: id(fields[:delivery_id]),
      channel_id: id(fields[:channel_id]),
      policy_id: id(fields[:policy_id]),
      route_id: id(fields[:route_id]),
      step_number: fields[:step_number],
      provider_key: classification(fields[:provider_key]),
      provider_type: classification(fields[:provider_type]),
      execution_route: classification(fields[:execution_route]),
      is_test: fields[:is_test] == true
    }
  end

  # An identifier passes through as-is; anything that is not a plain id - an
  # unloaded relationship, a struct someone passed by mistake - becomes nil
  # rather than being stringified into the metadata.
  defp id(value) when is_binary(value), do: value
  defp id(_value), do: nil

  # A classification is a bounded atom or short string. Structs and maps are
  # rejected outright: this is the field that would leak a payload if it ever
  # accepted one.
  defp classification(value) when is_atom(value) and not is_nil(value), do: value
  defp classification(value) when is_binary(value) and value != "", do: value
  defp classification(_value), do: nil

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(_value, default), do: default

  defp put_latency(measurements, _key, nil), do: measurements

  defp put_latency(measurements, key, value) when is_integer(value) and value >= 0 do
    Map.put(measurements, key, value)
  end

  defp put_latency(measurements, _key, _value), do: measurements

  defp emit(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
