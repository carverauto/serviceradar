defmodule ServiceRadar.EventWriter.Telemetry do
  @moduledoc """
  Low-cardinality telemetry helpers for EventWriter backpressure and throughput.

  Keep metadata bounded. Subjects are collapsed to coarse classes so metrics do
  not create one series per device, partition, or metric name.
  """

  @retention_warning_byte_ratio 0.75
  @retention_critical_byte_ratio 0.90
  @retention_warning_age_ratio 0.25
  @retention_critical_age_ratio 0.75

  @doc """
  Emits producer queue/in-flight state.
  """
  @spec emit_queue(map(), atom(), String.t() | nil) :: :ok
  def emit_queue(state, operation, subject \\ nil) when is_map(state) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :producer, :queue],
      %{
        queue_depth: non_negative(Map.get(state, :pending_count, 0)),
        demand: non_negative(Map.get(state, :demand, 0)),
        pull_inflight: non_negative(Map.get(state, :pull_inflight, 0)),
        max_buffered: non_negative(Map.get(state, :max_buffered, 0))
      },
      %{operation: operation, subject_class: subject_class(subject)}
    )

    :ok
  end

  @doc """
  Emits a stale pull-inflight expiry. Lost JetStream replies (consumer leader
  change, dropped empty-status) leave `pull_inflight_by_subject` pinned; the
  producer clears those slots after `stale_pull_timeout_ms/1`.
  """
  @spec emit_stale_pull(non_neg_integer(), non_neg_integer(), String.t() | nil) :: :ok
  def emit_stale_pull(expired_inflight, age_ms, subject)
      when is_integer(expired_inflight) and expired_inflight >= 0 and is_integer(age_ms) and
             age_ms >= 0 do
    :telemetry.execute(
      [:serviceradar, :event_writer, :producer, :stale_pull],
      %{
        count: 1,
        expired_inflight: non_negative(expired_inflight),
        age_ms: non_negative(age_ms)
      },
      %{subject_class: subject_class(subject)}
    )

    :ok
  end

  @doc """
  Emits a JetStream pull request event.
  """
  @spec emit_pull_request(non_neg_integer(), map(), map()) :: :ok
  def emit_pull_request(requested, state, metadata)
      when is_integer(requested) and requested >= 0 and is_map(state) and is_map(metadata) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :producer, :pull_request],
      %{
        messages: requested,
        queue_depth: non_negative(Map.get(state, :pending_count, 0)),
        demand: non_negative(Map.get(state, :demand, 0)),
        pull_inflight: non_negative(Map.get(state, :pull_inflight, 0)),
        max_buffered: non_negative(Map.get(state, :max_buffered, 0))
      },
      Map.merge(%{consumer_count: 0}, metadata)
    )

    :ok
  end

  @doc """
  Emits a per-message ack/nack result. `duration` is native monotonic time.
  """
  @spec emit_ack(atom(), :ok | :error, non_neg_integer() | nil, String.t() | nil) :: :ok
  def emit_ack(action, result, duration, subject) when action in [:ack, :nack, :term] do
    measurements = maybe_put(%{count: 1}, :duration, duration)

    :telemetry.execute(
      [:serviceradar, :event_writer, :ack],
      measurements,
      %{action: action, result: result, subject_class: subject_class(subject)}
    )

    :ok
  end

  @doc """
  Emits a terminal delivery event before EventWriter sends `+TERM`.
  """
  @spec emit_dead_letter(map()) :: :ok
  def emit_dead_letter(metadata) when is_map(metadata) do
    delivery_count = non_negative(metadata[:delivery_count])
    max_deliver = non_negative(metadata[:max_deliver])

    :telemetry.execute(
      [:serviceradar, :event_writer, :dead_letter],
      %{
        count: 1,
        delivery_count: delivery_count,
        max_deliver: max_deliver
      },
      %{
        # Keep raw subjects out of labels; stream/consumer are bounded configured
        # JetStream identifiers used to locate the terminal-delivery source.
        subject_class: subject_class(metadata[:subject]),
        stream: metadata[:stream] || "unknown",
        consumer: metadata[:consumer] || "unknown",
        reason_class: metadata[:reason_class] || "error"
      }
    )

    :ok
  end

  @doc """
  Emits a batch completion/failure event. `duration` is native monotonic time.
  """
  @spec emit_batch(atom(), [term()], non_neg_integer(), non_neg_integer(), map()) :: :ok
  def emit_batch(result, messages, rows, duration, metadata)
      when result in [:ok, :error] and is_list(messages) and is_map(metadata) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :batch, :completed],
      %{
        count: non_negative(rows),
        batch_size: length(messages),
        duration: non_negative(duration)
      },
      Map.merge(%{result: result, subject_class: batch_subject_class(messages)}, metadata)
    )

    :ok
  end

  @doc """
  Emits the JetStream server-side state for an EventWriter durable consumer.
  """
  @spec emit_consumer_state(map(), map()) :: :ok
  def emit_consumer_state(info, metadata) when is_map(info) and is_map(metadata) do
    emit_consumer_state(info, nil, metadata)
  end

  @doc """
  Emits consumer state together with authoritative JetStream stream retention state.

  `stream_info` is the response from `Gnat.Jetstream.API.Stream.info/2`. It is
  optional so non-flow consumers and temporary stream-info failures keep emitting
  the existing consumer backlog gauges.
  """
  @spec emit_consumer_state(map(), map() | nil, map()) :: :ok
  def emit_consumer_state(info, stream_info, metadata)
      when is_map(info) and (is_map(stream_info) or is_nil(stream_info)) and is_map(metadata) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :consumer, :state],
      consumer_state_measurements(info, stream_info),
      %{
        stream: metadata[:stream] || "unknown",
        durable: metadata[:durable] || "unknown",
        subject_class: metadata[:subject_class] || "unknown"
      }
    )

    :ok
  end

  @doc """
  Emits a bounded error signal when consumer state polling fails.
  """
  @spec emit_consumer_state_error(term(), map()) :: :ok
  def emit_consumer_state_error(reason, metadata) when is_map(metadata) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :consumer, :poll_error],
      %{count: 1},
      %{
        stream: metadata[:stream] || "unknown",
        durable: metadata[:durable] || "unknown",
        subject_class: metadata[:subject_class] || "unknown",
        reason_class: reason_class(reason)
      }
    )

    :ok
  end

  @doc """
  Collapses NATS subjects into bounded classes for metric labels.
  """
  @spec subject_class(term()) :: String.t()
  def subject_class(subject) when is_binary(subject) do
    cond do
      String.starts_with?(subject, "metrics.") -> "metrics"
      String.starts_with?(subject, "otel.metrics.") -> "otel_metrics"
      String.starts_with?(subject, "otel.traces.") -> "otel_traces"
      String.starts_with?(subject, "otel.logs.") -> "otel_logs"
      String.starts_with?(subject, "logs.") -> "logs"
      String.starts_with?(subject, "events.") -> "events"
      String.starts_with?(subject, "flows.") or String.starts_with?(subject, "flow.") -> "flows"
      String.starts_with?(subject, "pdns.") -> "pdns"
      String.starts_with?(subject, "falco.") -> "falco"
      String.starts_with?(subject, "trivy.") -> "trivy"
      String.starts_with?(subject, "sweep.") -> "sweep"
      String.starts_with?(subject, "signals.analytics.") -> "analytics"
      String.starts_with?(subject, "causal.") -> "causal"
      subject == "" -> "unknown"
      true -> "other"
    end
  end

  def subject_class(_subject), do: "unknown"

  @doc false
  @spec consumer_state_measurements(map()) :: map()
  def consumer_state_measurements(info) when is_map(info) do
    consumer_state_measurements(info, nil)
  end

  @doc false
  @spec consumer_state_measurements(map(), map() | nil) :: map()
  def consumer_state_measurements(info, stream_info)
      when is_map(info) and (is_map(stream_info) or is_nil(stream_info)) do
    consumer_state_measurements(info, stream_info, DateTime.utc_now())
  end

  @doc false
  @spec consumer_state_measurements(map(), map() | nil, DateTime.t()) :: map()
  def consumer_state_measurements(info, stream_info, %DateTime{} = now)
      when is_map(info) and (is_map(stream_info) or is_nil(stream_info)) do
    pending = non_negative(get_value(info, :num_pending))
    ack_pending = non_negative(get_value(info, :num_ack_pending))
    redelivered = non_negative(get_value(info, :num_redelivered))
    waiting = non_negative(get_value(info, :num_waiting))
    backlog = pending + ack_pending

    retention = stream_retention_measurements(stream_info, now)

    Map.merge(
      %{
        pending_messages: pending,
        ack_pending_messages: ack_pending,
        redelivered_messages: redelivered,
        waiting_pulls: waiting,
        lag_messages: backlog,
        delivered_consumer_sequence: nested_non_negative(info, :delivered, :consumer_seq),
        ack_floor_consumer_sequence: nested_non_negative(info, :ack_floor, :consumer_seq),
        delivered_stream_sequence: nested_non_negative(info, :delivered, :stream_seq),
        ack_floor_stream_sequence: nested_non_negative(info, :ack_floor, :stream_seq),
        retention_risk_level: retention_risk_level(backlog, retention)
      },
      retention
    )
  end

  defp stream_retention_measurements(nil, _now) do
    %{
      stream_info_available: 0,
      stream_bytes: 0,
      stream_max_bytes: 0,
      stream_byte_utilization_ratio: 0.0,
      stream_first_message_age_seconds: 0.0,
      stream_max_age_seconds: 0.0,
      stream_age_utilization_ratio: 0.0
    }
  end

  defp stream_retention_measurements(stream_info, now) when is_map(stream_info) do
    config = get_value(stream_info, :config)
    state = get_value(stream_info, :state)
    bytes = non_negative(get_value(state, :bytes))
    max_bytes = positive_limit(get_value(config, :max_bytes))
    max_age_seconds = nanoseconds_to_seconds(positive_limit(get_value(config, :max_age)))

    first_message_age_seconds =
      first_message_age_seconds(
        get_value(state, :first_ts),
        non_negative(get_value(state, :messages)),
        now
      )

    %{
      stream_info_available: 1,
      stream_bytes: bytes,
      stream_max_bytes: max_bytes,
      stream_byte_utilization_ratio: utilization_ratio(bytes, max_bytes),
      stream_first_message_age_seconds: first_message_age_seconds,
      stream_max_age_seconds: max_age_seconds,
      stream_age_utilization_ratio: utilization_ratio(first_message_age_seconds, max_age_seconds)
    }
  end

  defp batch_subject_class([message | _]) do
    metadata = Map.get(message, :metadata) || %{}
    subject_class(metadata[:base_subject] || metadata[:subject])
  end

  defp batch_subject_class(_), do: "unknown"

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(value) when is_float(value) and value >= 0, do: value
  defp non_negative(_), do: 0

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, non_negative(value))

  defp nested_non_negative(info, key, nested_key) do
    info
    |> get_value(key)
    |> get_value(nested_key)
    |> non_negative()
  end

  defp get_value(nil, _key), do: nil

  defp get_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp get_value(_value, _key), do: nil

  defp positive_limit(value) when is_integer(value) and value > 0, do: value
  defp positive_limit(value) when is_float(value) and value > 0, do: value
  defp positive_limit(_value), do: 0

  defp nanoseconds_to_seconds(nanoseconds) when nanoseconds > 0, do: nanoseconds / 1_000_000_000

  defp nanoseconds_to_seconds(_nanoseconds), do: 0.0

  defp first_message_age_seconds(_first_ts, messages, _now) when messages <= 0, do: 0.0

  defp first_message_age_seconds(%DateTime{} = first_ts, _messages, now) do
    max(DateTime.diff(now, first_ts, :millisecond) / 1_000, 0.0)
  end

  defp first_message_age_seconds(first_ts, messages, now) when is_binary(first_ts) do
    case DateTime.from_iso8601(first_ts) do
      {:ok, parsed, _offset} -> first_message_age_seconds(parsed, messages, now)
      _ -> 0.0
    end
  end

  defp first_message_age_seconds(_first_ts, _messages, _now), do: 0.0

  defp utilization_ratio(value, limit) when is_number(value) and is_number(limit) and limit > 0,
    do: value / limit

  defp utilization_ratio(_value, _limit), do: 0.0

  defp retention_risk_level(backlog, _retention) when backlog <= 0, do: 0

  defp retention_risk_level(backlog, retention) when backlog > 0 do
    byte_ratio = retention.stream_byte_utilization_ratio
    age_ratio = retention.stream_age_utilization_ratio

    cond do
      byte_ratio >= @retention_critical_byte_ratio or
          age_ratio >= @retention_critical_age_ratio ->
        2

      byte_ratio >= @retention_warning_byte_ratio or
          age_ratio >= @retention_warning_age_ratio ->
        1

      true ->
        0
    end
  end

  defp reason_class(:not_connected), do: "not_connected"
  defp reason_class(:connection_dead), do: "connection_dead"
  defp reason_class({:exit, _reason}), do: "exit"

  defp reason_class(%{"code" => code}) when is_integer(code), do: "nats_#{code}"
  defp reason_class(%{"description" => description}) when is_binary(description), do: "nats_error"
  defp reason_class(%_{}), do: "exception"
  defp reason_class(_reason), do: "error"
end
