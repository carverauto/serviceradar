defmodule ServiceRadar.Edge.Projectors.TelemetryBatch do
  @moduledoc """
  Projects `serviceradar.telemetry.batch` edge records onto the destinations
  plugin and add-on telemetry has today.

  The legacy path sends an SDK `TelemetryBatch` as a gateway status push: the
  gateway publishes its `serviceradar_metrics` records onto
  `metrics.timeseries.<type>.<name>` (attested to the authenticated agent),
  and core's `ServiceRadar.Ingestion.StatusIngestor` routes the OCSF event
  and OTel log records to their streams and feeds `discovery_v1` records to
  the discovery ingestor. This projector does exactly that routing for a
  durable record, so storage and every downstream consumer are unchanged:

    * `serviceradar_metrics` records are attested here (the gateway never
      decodes a durable payload) and published with a PubAck under a
      deterministic per-record message id derived from the record's event
      id, so the redelivery of a record whose ledger commit failed after the
      publish is stored once within the stream's duplicate window.
    * Every other admitted kind goes through the status ingestor under the
      same `plugin:<id>` / `addon:<id>` source the agent's status push
      carried, which routes OCSF events, OTel logs and discovery to today's
      destinations and no-ops the metric records this projector handled.

  Which instance produced a batch comes from the host stamp the agent writes
  into the batch source metadata (`serviceradar.producer_type` /
  `serviceradar.producer_id`) from its own assignment and add-on
  configuration; a guest-supplied value is overwritten before spooling, so
  the stamp cannot reattribute one instance's telemetry to another.

  Before routing, the record's standing grant is re-checked
  (`OutputGrants.check_current/5`); a grant that is not current refuses the
  record. The one identity the durable path cannot carry is the connecting
  gateway's id and source address, which the legacy status push attested:
  projected envelopes leave them unset rather than guessing.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Actors.SystemActor
  alias Serviceradar.Agent.Addon.V1.TelemetryBatch, as: Batch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Ingestion.StatusIngestor
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadar.NATS.JetStreamPublish

  require Logger

  @schema "serviceradar.metric.v1"
  @producer_type_key "serviceradar.producer_type"
  @producer_id_key "serviceradar.producer_id"

  # The payload kinds this contract routes. The OTLP relay kinds ride their
  # own contract; anything else is refused at decode, never dropped silently
  # route-by-route.
  @routed_kinds [
    :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
    :TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
    :TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
    :TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1
  ]

  @doc """
  Decodes and validates the batch of a telemetry record: no source
  authorization, at least one record, one projected row per record, a host
  producer stamp, every payload kind in the routed set, and discovery
  records only from a native add-on.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %Batch{} = batch} <- WireDecode.decode_telemetry_batch(body),
         :ok <- check(batch.records != [], :telemetry_batch_empty),
         :ok <-
           check(length(batch.records) == record.projected_row_count, :telemetry_batch_row_count),
         {:ok, producer} <- producer(batch),
         :ok <- check_kinds(batch.records, producer) do
      {:ok, {batch, body, producer}}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :telemetry_batch_source_authorization}

  @doc """
  Routes the batch of a fresh primary record after checking its grant is
  still current. Metric records publish first (their deterministic message
  ids make a redelivery after a later failure store once); a failed publish
  is an error so the batch is redelivered. An OCSF, OTel, or discovery
  publish that fails its transport is the same kind of error. Guest spool
  counters are emitted only after the metric publish and that route both
  succeed, so a redelivery does not count the batch twice.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, {%Batch{} = batch, body, producer}, opts) do
    context = record.producer_context
    agent_id = context.origin_principal_id

    with :ok <-
           OutputGrants.check_current(
             Ecto.UUID.load!(context.producer_assignment_id),
             agent_id,
             record.output_contract.contract_id,
             Ecto.UUID.load!(record.network_scope_id),
             context.authority_epoch
           ),
         {:ok, partition} <- partition(record.network_scope_id),
         :ok <- publish_metrics(record, batch, producer, agent_id, partition, opts),
         :ok <- route_via_status_ingestor(body, producer, agent_id, partition) do
      emit_spool_counters(batch, producer, agent_id)
    else
      {:error, :output_grant_not_current} -> {:refused, :output_grant_not_current}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_metrics(record, batch, producer, agent_id, partition, opts) do
    event_id = Ecto.UUID.load!(record.event_id)

    batch.records
    |> Enum.with_index()
    |> Enum.filter(
      &match?(
        {%TelemetryRecord{payload_kind: :TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS}, _},
        &1
      )
    )
    |> Enum.reduce_while(:ok, fn {telemetry_record, index}, :ok ->
      case publish_metric_record(
             telemetry_record,
             producer,
             agent_id,
             partition,
             event_id,
             index,
             opts
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp publish_metric_record(
         telemetry_record,
         producer,
         agent_id,
         partition,
         event_id,
         index,
         opts
       ) do
    case WireDecode.decode_metric_batch(telemetry_record.payload || "") do
      {:ok, %MetricBatch{schema_version: @schema, metrics: [_ | _]} = metric_batch} ->
        msg_id = derived_msg_id(event_id, index)
        attested = attest(metric_batch, producer, agent_id, partition, msg_id)
        publish_opts = [msg_id: msg_id] ++ Keyword.take(opts, [:request])

        case JetStreamPublish.publish(
               subject(attested),
               MetricBatch.encode(attested),
               publish_opts
             ) do
          :ok -> :ok
          {:error, reason} -> {:error, {:telemetry_metrics_publish_failed, reason}}
        end

      _ ->
        :telemetry.execute([:serviceradar, :plugin_metrics, :decode_failed], %{count: 1}, %{
          agent_id: agent_id,
          producer_id: producer.id
        })

        Logger.warning("Plugin metrics decode failed for telemetry batch record",
          agent_id: agent_id,
          producer_id: producer.id
        )

        :ok
    end
  end

  # The same attestation the gateway stamps for a legacy status push, with
  # the fields only this path knows: the authenticated agent, its partition,
  # and the host-stamped producer. The gateway id and source address a status
  # push carried have no durable-record counterpart and stay unset.
  defp attest(batch, producer, agent_id, partition, ingress_id) do
    resource = batch.resource || %MetricResource{}
    identity = batch.ingest_identity || %IngestIdentity{}
    {service_name, service_type} = legacy_service(producer)

    %{
      batch
      | resource: %{
          resource
          | agent_id: agent_id,
            gateway_id: "",
            partition: partition,
            service_name: service_name,
            service_type: service_type
        },
        ingest_identity: %{
          identity
          | source: attested_source(producer),
            payload_kind: @schema,
            producer_id: attested_producer_id(producer, service_name),
            producer_kind: service_type,
            attested_by: agent_id
        },
        ingress_id: ingress_id,
        ingress_timestamp_unix_nano: System.system_time(:nanosecond)
    }
  end

  defp route_via_status_ingestor(body, producer, agent_id, partition) do
    {service_name, service_type} = legacy_service(producer)

    status = %{
      agent_id: agent_id,
      partition: partition,
      service_name: service_name,
      service_type: service_type,
      source: "#{producer.type}:#{producer.id}",
      message: body,
      available: true
    }

    case StatusIngestor.ingest(status, return_transport_errors: true) do
      :ok -> :ok
      {:error, reason} -> {:error, {:telemetry_route_failed, reason}}
    end
  end

  defp legacy_service(%{type: "plugin"}), do: {"plugin-telemetry", "plugin"}
  defp legacy_service(%{type: "addon"}), do: {"addon-telemetry", "native-addon"}

  defp attested_source(%{type: "plugin"}), do: "wasm-plugin"
  defp attested_source(%{type: "addon"}), do: "native-addon"

  defp attested_producer_id(%{type: "plugin", id: id}, _service_name), do: id
  defp attested_producer_id(%{type: "addon"}, service_name), do: service_name

  # The producer spool counters the gateway used to emit for a legacy
  # status push, under the same event and measurements.
  defp emit_spool_counters(%Batch{counters: nil}, _producer, _agent_id), do: :ok

  defp emit_spool_counters(%Batch{counters: counters}, producer, agent_id) do
    :telemetry.execute(
      [:serviceradar, :plugin_metrics, :spool],
      %{
        received: counters.received || 0,
        filtered: counters.filtered || 0,
        emitted: counters.emitted || 0,
        dropped: counters.dropped || 0,
        queue_depth: counters.queue_depth || 0
      },
      %{agent_id: agent_id, producer_id: producer.id}
    )
  end

  # Same subject the gateway derives: metrics.timeseries, then the first
  # metric's type and name as safe subject tokens.
  defp subject(%MetricBatch{metrics: [metric | _]}) do
    type = token(metric.metric_type) || "custom"
    name = token(metric.name) || "unknown"
    "metrics.timeseries.#{type}.#{name}"
  end

  defp token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      token -> token
    end
  end

  defp token(_value), do: nil

  # One deterministic message id per metric payload in the batch: the same
  # redelivered record derives the same ids, so the stream's duplicate
  # window stores each publish once.
  defp derived_msg_id(event_id, index) do
    <<bytes::binary-size(16), _::binary>> =
      :crypto.hash(
        :sha256,
        "serviceradar.telemetry.batch:" <> event_id <> ":" <> Integer.to_string(index)
      )

    Ecto.UUID.load!(bytes)
  end

  defp partition(network_scope_id) do
    with {:ok, scope_id} <- Ecto.UUID.load(network_scope_id),
         {:ok, partition} <-
           Partition.get_by_id(scope_id, actor: SystemActor.system(:telemetry_batch_projector)) do
      {:ok, partition.slug}
    else
      _ -> {:error, :telemetry_batch_partition}
    end
  end

  defp producer(%Batch{source: source}) do
    metadata = (source && source.metadata) || %{}
    type = metadata |> Map.get(@producer_type_key, "") |> to_string() |> String.trim()
    id = metadata |> Map.get(@producer_id_key, "") |> to_string() |> String.trim()

    if type in ["plugin", "addon"] and id != "" do
      {:ok, %{type: type, id: id}}
    else
      {:error, :telemetry_batch_producer}
    end
  end

  defp check_kinds(records, producer) do
    Enum.reduce_while(records, :ok, fn %TelemetryRecord{payload_kind: kind}, :ok ->
      cond do
        kind not in @routed_kinds ->
          {:halt, {:error, :telemetry_batch_payload_kind}}

        kind == :TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1 and producer.type != "addon" ->
          {:halt, {:error, :telemetry_batch_discovery_producer}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
