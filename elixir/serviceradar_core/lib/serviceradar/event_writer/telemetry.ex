defmodule ServiceRadar.EventWriter.Telemetry do
  @moduledoc """
  Low-cardinality telemetry helpers for EventWriter backpressure and throughput.

  Keep metadata bounded. Subjects are collapsed to coarse classes so metrics do
  not create one series per device, partition, or metric name.
  """

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
  def emit_ack(action, result, duration, subject) when action in [:ack, :nack] do
    measurements = maybe_put(%{count: 1}, :duration, duration)

    :telemetry.execute(
      [:serviceradar, :event_writer, :ack],
      measurements,
      %{action: action, result: result, subject_class: subject_class(subject)}
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
    :telemetry.execute(
      [:serviceradar, :event_writer, :consumer, :state],
      consumer_state_measurements(info),
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
      String.starts_with?(subject, "causal.") -> "causal"
      subject == "" -> "unknown"
      true -> "other"
    end
  end

  def subject_class(_subject), do: "unknown"

  @doc false
  @spec consumer_state_measurements(map()) :: map()
  def consumer_state_measurements(info) when is_map(info) do
    pending = non_negative(get_value(info, :num_pending))
    ack_pending = non_negative(get_value(info, :num_ack_pending))
    redelivered = non_negative(get_value(info, :num_redelivered))
    waiting = non_negative(get_value(info, :num_waiting))
    backlog = pending + ack_pending

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
      retention_risk_level: retention_risk_level(backlog, redelivered)
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

  defp retention_risk_level(backlog, redelivered) when backlog > 0 and redelivered > 0, do: 2
  defp retention_risk_level(backlog, _redelivered) when backlog > 0, do: 1
  defp retention_risk_level(_backlog, _redelivered), do: 0

  defp reason_class(:not_connected), do: "not_connected"
  defp reason_class(:connection_dead), do: "connection_dead"
  defp reason_class({:exit, _reason}), do: "exit"

  defp reason_class(%{"code" => code}) when is_integer(code), do: "nats_#{code}"
  defp reason_class(%{"description" => description}) when is_binary(description), do: "nats_error"
  defp reason_class(%_{}), do: "exception"
  defp reason_class(_reason), do: "error"
end
