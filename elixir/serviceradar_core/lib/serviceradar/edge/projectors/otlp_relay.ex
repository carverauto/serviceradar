defmodule ServiceRadar.Edge.Projectors.OtlpRelay do
  @moduledoc """
  Projects `serviceradar.otlp.relay` v1 records onto the canonical OTLP JetStream subjects
  (`otel.traces.raw`, `logs.otel`, `otel.metrics.raw`, `otel.metrics.derived`).

  The legacy status path sends an agent's `TelemetryBatch` inside an `otlp-relay` status to
  the gateway (`ServiceRadarAgentGateway.OtlpRelayPublisher`), which emits
  `[:serviceradar, :otlp_relay, :spool]` counters, stamps `Sr-*` attribution headers from the
  authenticated session, and publishes each `TelemetryRecord.payload` verbatim to its OTLP
  subject while emitting `[:serviceradar, :event_writer, :signal]` (`outcome: :relayed`).

  This projector decodes an `OtlpRelayFrame` from an authenticated `EdgeRecordV1`, resolves
  the partition slug from `record.network_scope_id` via `Partition.get_by_id/2` (refusing the
  record when no partition row exists, never substituting `"default"` or raw scope bytes),
  takes `agent_id` from `record.producer_context.origin_principal_id`, and republishes each
  routable `TelemetryRecord` before the EdgeRecord ledger transaction. Spool telemetry from
  `frame.batch.counters` is emitted from `committed/3` only after that ledger commit.
  Each published chunk carries `Nats-Msg-Id` set to
  that `TelemetryRecord`'s `event_id` and waits for a JetStream PubAck; the `:relayed` signal
  counter is emitted only when the PubAck is not a duplicate. An unroutable `payload_kind` is
  dropped with `[:serviceradar, :otlp_relay, :record_rejected]` rather than failing the batch.
  """

  @behaviour ServiceRadar.Edge.Projector

  import Bitwise

  alias ServiceRadar.Actors.SystemActor
  alias Serviceradar.Agent.Addon.V1.OtlpRelayFrame
  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryCounters
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.EventWriter.SignalTelemetry
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.NATS.JetStreamPublish

  require Logger

  @max_records_per_batch 1_024
  @max_timestamp (1 <<< 60) - 1
  @max_random (1 <<< 62) - 1

  @telemetry_otlp_relay_spool [:serviceradar, :otlp_relay, :spool]
  @telemetry_otlp_relay_rejected [:serviceradar, :otlp_relay, :record_rejected]

  @doc """
  Decodes and validates the `OtlpRelayFrame` of an OTLP relay edge record:
  no source authorization, `EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1`, `relay_id > 0`,
  non-empty `batch.records` (`<= 1,024`), `projected_row_count == length(batch.records)`,
  `projected_write_bytes == uncompressed_size`, and non-empty `payload` bytes on every record.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %OtlpRelayFrame{} = frame} <- WireDecode.decode_otlp_relay_frame(body),
         :ok <- check((frame.relay_id || 0) > 0, :otlp_relay_id),
         :ok <- check(match?(%TelemetryBatch{}, frame.batch), :otlp_relay_batch_missing),
         :ok <- check(frame.batch.records != [], :otlp_relay_records_empty),
         :ok <-
           check(
             length(frame.batch.records) <= @max_records_per_batch,
             :otlp_relay_too_many_records
           ),
         :ok <-
           check(
             length(frame.batch.records) == record.projected_row_count,
             :otlp_relay_row_count
           ),
         :ok <-
           check(
             record.projected_write_bytes == record.uncompressed_size,
             :otlp_relay_write_bytes
           ),
         :ok <-
           check(
             Enum.all?(frame.batch.records, &non_empty_payload?/1),
             :otlp_relay_record_payload
           ) do
      {:ok, frame}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :otlp_relay_source_authorization}

  @doc """
  Publishes the OTLP relay chunks of a fresh primary delivery before the ledger transaction.
  Re-checks the standing output grant (`OutputGrants.check_current/5`), resolves the partition
  slug from `record.network_scope_id`, and publishes each routable record waiting for its
  JetStream PubAck.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %OtlpRelayFrame{batch: %TelemetryBatch{} = batch}, opts) do
    context = record.producer_context
    agent_id = context.origin_principal_id
    network_scope_id = Ecto.UUID.load!(record.network_scope_id)

    with :ok <-
           OutputGrants.check_current(
             Ecto.UUID.load!(context.producer_assignment_id),
             agent_id,
             record.output_contract.contract_id,
             network_scope_id,
             context.authority_epoch
           ),
         {:ok, %Partition{slug: partition_slug}} <- fetch_partition(network_scope_id) do
      metadata = %{partition_id: partition_slug, agent_id: agent_id}
      base_headers = base_headers(partition_slug, agent_id)
      subjects = subjects(opts)

      batch.records
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {%TelemetryRecord{} = telemetry_record, index}, :ok ->
        publish_record(
          telemetry_record,
          index,
          record.event_id,
          subjects,
          base_headers,
          metadata,
          opts
        )
      end)
    else
      {:error, reason}
      when reason in [:output_grant_not_current, :otlp_relay_partition_not_found] ->
        {:refused, reason}
    end
  end

  @doc """
  Verifies inside the EdgeRecord ledger transaction that a primary delivery's standing grant
  and partition row remain valid.
  """
  @impl true
  def project(repo, %EdgeRecordV1{} = record, %OtlpRelayFrame{}, %{primary?: true}) do
    producer = record.producer_context
    network_scope_id = Ecto.UUID.load!(record.network_scope_id)
    agent_id = producer.origin_principal_id

    with :ok <-
           OutputGrants.check_current(
             Ecto.UUID.load!(producer.producer_assignment_id),
             agent_id,
             record.output_contract.contract_id,
             network_scope_id,
             producer.authority_epoch
           ),
         %Partition{} <- repo.get(Partition, network_scope_id) do
      :ok
    else
      nil -> {:error, :otlp_relay_partition_not_found}
      {:error, _reason} = error -> error
    end
  end

  def project(_repo, _record, _frame, _context), do: :ok

  @doc """
  Emits `[:serviceradar, :otlp_relay, :spool]` after the primary EdgeRecord ledger
  transaction commits. A partition read failure misses that sample and returns `:ok`.
  """
  @impl true
  def committed(
        %EdgeRecordV1{} = record,
        %OtlpRelayFrame{batch: %TelemetryBatch{} = batch},
        %{primary?: true}
      ) do
    network_scope_id = Ecto.UUID.load!(record.network_scope_id)
    agent_id = record.producer_context.origin_principal_id

    case partition_for_committed_sample(network_scope_id) do
      {:ok, %Partition{slug: partition_slug}} ->
        emit_spool_counters(batch.counters, partition_slug, agent_id)

      :miss ->
        :ok
    end

    :ok
  end

  def committed(_record, _frame, _context), do: :ok

  defp publish_record(
         %TelemetryRecord{} = telemetry_record,
         index,
         edge_event_id,
         subjects,
         base_headers,
         metadata,
         opts
       ) do
    case route(telemetry_record.payload_kind, subjects) do
      {:ok, subject, signal} ->
        ingress_time = System.system_time(:nanosecond)
        ingress_id = new_ingress_id(ingress_time)
        msg_id = record_msg_id(telemetry_record.event_id, edge_event_id, index)

        headers =
          base_headers ++
            [
              {"Sr-Ingress-Id", ingress_id},
              {"Sr-Ingress-Time-Unix-Nano", Integer.to_string(ingress_time)}
            ]

        case publish_chunk(subject, telemetry_record.payload, msg_id, headers, opts) do
          {:ok, %{duplicate?: true}} ->
            {:cont, :ok}

          {:ok, %{duplicate?: false}} ->
            SignalTelemetry.emit(signal, :relayed, 1)
            {:cont, :ok}

          :ok ->
            SignalTelemetry.emit(signal, :relayed, 1)
            {:cont, :ok}

          {:error, reason} ->
            Logger.warning(
              "OtlpRelay projector: failed to publish otlp-relay record",
              subject: subject,
              reason: inspect(reason),
              partition_id: metadata.partition_id,
              agent_id: metadata.agent_id
            )

            {:halt, {:error, {:otlp_relay_publish_failed, reason}}}
        end

      :error ->
        :telemetry.execute(@telemetry_otlp_relay_rejected, %{count: 1}, metadata)

        Logger.warning(
          "OtlpRelay projector: dropping otlp-relay record with unroutable payload kind",
          payload_kind: inspect(telemetry_record.payload_kind),
          event_id: telemetry_record.event_id,
          partition_id: metadata.partition_id,
          agent_id: metadata.agent_id
        )

        {:cont, :ok}
    end
  end

  defp publish_chunk(subject, payload, msg_id, headers, opts) do
    case Keyword.get(opts, :otlp_relay_publisher) do
      fun when is_function(fun, 4) ->
        fun.(subject, payload, msg_id, headers)

      fun when is_function(fun, 3) ->
        fun.(subject, payload, [{"Nats-Msg-Id", msg_id} | headers])

      nil ->
        publish_opts = [msg_id: msg_id, headers: headers] ++ Keyword.take(opts, [:request])
        JetStreamPublish.publish_with_ack(subject, payload, publish_opts)
    end
  end

  defp record_msg_id(event_id, _edge_event_id, _index)
       when is_binary(event_id) and event_id != "" do
    trimmed = String.trim(event_id)
    if trimmed == "", do: nil, else: trimmed
  end

  defp record_msg_id(_event_id, <<_::128>> = edge_event_id, index) do
    Ecto.UUID.load!(edge_event_id) <> ":" <> Integer.to_string(index)
  end

  defp record_msg_id(_event_id, _edge_event_id, index), do: Integer.to_string(index)

  defp base_headers(partition_id, agent_id) do
    [
      {"Sr-Agent-Id", agent_id},
      {"Sr-Partition", partition_id},
      {"Sr-Ingest-Identity", "agent:" <> agent_id}
    ]
  end

  defp subjects(opts) do
    config =
      :serviceradar_core
      |> Application.get_env(:otlp_relay_publisher, [])
      |> Keyword.merge(
        Keyword.take(opts, [
          :traces_subject,
          :logs_subject,
          :metrics_subject,
          :derived_metrics_subject
        ])
      )

    [
      traces:
        Keyword.get_lazy(config, :traces_subject, fn ->
          env_or_default("AGENT_GATEWAY_OTLP_RELAY_TRACES_SUBJECT", "otel.traces.raw")
        end),
      logs:
        Keyword.get_lazy(config, :logs_subject, fn ->
          env_or_default("AGENT_GATEWAY_OTLP_RELAY_LOGS_SUBJECT", "logs.otel")
        end),
      metrics:
        Keyword.get_lazy(config, :metrics_subject, fn ->
          env_or_default("AGENT_GATEWAY_OTLP_RELAY_METRICS_SUBJECT", "otel.metrics.raw")
        end),
      derived_metrics:
        Keyword.get_lazy(config, :derived_metrics_subject, fn ->
          env_or_default(
            "AGENT_GATEWAY_OTLP_RELAY_DERIVED_METRICS_SUBJECT",
            "otel.metrics.derived"
          )
        end)
    ]
  end

  defp env_or_default(env_key, default) do
    case System.get_env(env_key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp route(kind, subjects) when kind in [:TELEMETRY_PAYLOAD_KIND_OTLP_TRACES, 3],
    do: {:ok, subjects[:traces], :traces}

  defp route(kind, subjects) when kind in [:TELEMETRY_PAYLOAD_KIND_OTLP_LOGS, 4],
    do: {:ok, subjects[:logs], :logs}

  defp route(kind, subjects) when kind in [:TELEMETRY_PAYLOAD_KIND_OTLP_METRICS, 5],
    do: {:ok, subjects[:metrics], :metric_points}

  defp route(kind, subjects) when kind in [:TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC, 6],
    do: {:ok, subjects[:derived_metrics], :metrics}

  defp route(_kind, _subjects), do: :error

  defp emit_spool_counters(%TelemetryCounters{} = counters, partition_id, agent_id) do
    :telemetry.execute(
      @telemetry_otlp_relay_spool,
      %{
        received: counters.received || 0,
        filtered: counters.filtered || 0,
        emitted: counters.emitted || 0,
        dropped: counters.dropped || 0,
        queue_depth: counters.queue_depth || 0
      },
      %{partition_id: partition_id, agent_id: agent_id}
    )
  end

  defp emit_spool_counters(_counters, _partition_id, _agent_id), do: :ok

  defp fetch_partition(network_scope_id) do
    case read_partition(network_scope_id) do
      {:ok, %Partition{} = partition} ->
        {:ok, partition}

      {:error, :otlp_relay_partition_not_found} = error ->
        error

      {:error, error} ->
        raise error
    end
  end

  defp partition_for_committed_sample(network_scope_id) do
    case read_partition(network_scope_id) do
      {:ok, %Partition{} = partition} -> {:ok, partition}
      {:error, _reason} -> :miss
    end
  rescue
    _exception -> :miss
  end

  defp read_partition(network_scope_id) do
    case Partition.get_by_id(network_scope_id, actor: actor()) do
      {:ok, %Partition{} = partition} ->
        {:ok, partition}

      {:ok, nil} ->
        {:error, :otlp_relay_partition_not_found}

      {:error, error} ->
        if partition_not_found?(error) do
          {:error, :otlp_relay_partition_not_found}
        else
          {:error, error}
        end
    end
  end

  defp partition_not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp partition_not_found?(%Ash.Error.Invalid{}), do: true

  defp partition_not_found?(%{errors: errors}) when is_list(errors) do
    errors != [] and Enum.all?(errors, &partition_not_found?/1)
  end

  defp partition_not_found?(_error), do: false

  defp non_empty_payload?(%TelemetryRecord{payload: payload})
       when is_binary(payload) and byte_size(payload) > 0, do: true

  defp non_empty_payload?(_record), do: false

  # UUIDv8-shaped k-sortable ingress identifier matching ServiceRadarAgentGateway.IngressId.new/1.
  defp new_ingress_id(timestamp_unix_nano) when is_integer(timestamp_unix_nano) do
    timestamp_micros =
      timestamp_unix_nano
      |> div(1_000)
      |> Bitwise.band(@max_timestamp)

    <<time_high::48, time_low::12>> = <<timestamp_micros::60>>
    <<raw_rand::64>> = :crypto.strong_rand_bytes(8)
    random = Bitwise.band(raw_rand, @max_random)

    format_uuid(<<time_high::48, 8::4, time_low::12, 2::2, random::62>>)
  end

  defp format_uuid(<<uuid::128>>) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
      Base.encode16(<<uuid::128>>, case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  defp actor, do: SystemActor.system(:otlp_relay_projector)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
