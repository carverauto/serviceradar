defmodule ServiceRadar.Edge.MetricsBatchProjection do
  @moduledoc """
  Projects `serviceradar.metrics.batch` edge records onto the metrics stream.

  The legacy status path hands an agent's `metric.v1.MetricBatch` to the gateway, which attests
  it and publishes it to `metrics.<family>.<type>.<name>`, where
  `ServiceRadar.EventWriter.Processors.Metrics` persists it (StarRocks when enabled, CNPG
  otherwise) and every other `metrics.>` consumer sees it. This projector publishes the batch of
  a durable record to exactly that subject, so storage, alerting and real-time consumers are
  unchanged and a metric still reaches the database only through JetStream.

  Before publishing it re-checks the record's standing grant (`OutputGrants.check_current/5`)
  and stamps the authenticated agent id over whatever the body claims, as the gateway does for a
  status push. The publish waits for the stream's PubAck and names the record's event id as its
  `Nats-Msg-Id`, so the redelivery of a record whose ledger commit failed after the publish is
  stored once within the stream's duplicate window. `ServiceRadar.EventWriter.Processors.EdgeRecord`
  publishes before its ledger transaction, never inside it, and skips the publish for a replay or
  a late-fenced delivery.

  The batch's ingest identity source selects the family from a closed list, the same one the
  gateway routes for these producers, with the gateway's producer kinds: `sysmon-metrics`,
  `snmp-metrics`, `icmp-metrics`, `rperf-metrics`, `mtr-metrics` (MTR scalar metrics, not
  traces) and `sweep-metrics` (the periodic sweep summary) publish on `metrics.sysmon.>`,
  `metrics.snmp.>`, `metrics.icmp.>`, `metrics.rperf.>`, `metrics.mtr.>` and
  `metrics.sweep.>`. Any other source is refused, never published under a guessed subject.
  Adding an agent-scheduled metric producer is one entry in that list plus core's NATS publish
  permission for its subject.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadar.NATS.JetStreamPublish

  @schema "serviceradar.metric.v1"

  # A body past this does not fit one NATS message under the default 1 MiB max_payload with
  # header headroom; the agent caps each record's body at 512 KiB.
  @max_body_bytes 900 * 1024

  # ingest identity source => {subject family, producer kind}, matching the gateway publishers.
  @families %{
    "sysmon-metrics" => {"sysmon", "agent"},
    "snmp-metrics" => {"snmp", "agent"},
    "icmp-metrics" => {"icmp", "agent"},
    "rperf-metrics" => {"rperf", "rperf-checker"},
    "mtr-metrics" => {"mtr", "mtr-checker"},
    "sweep-metrics" => {"sweep", "sweep"}
  }

  @doc """
  Decodes and validates the batch of a metrics record: no source authorization, the metric
  schema, at least one metric, one projected row per metric, a known source, and a body that
  fits one stream message.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         :ok <- check(byte_size(body) <= @max_body_bytes, :metrics_batch_too_large),
         {:ok, %MetricBatch{} = batch} <- WireDecode.decode_metric_batch(body),
         :ok <- check(batch.schema_version == @schema, :metrics_batch_schema),
         :ok <- check(batch.metrics != [], :metrics_batch_empty),
         :ok <-
           check(length(batch.metrics) == record.projected_row_count, :metrics_batch_row_count),
         :ok <- check(Map.has_key?(@families, source(batch)), :metrics_batch_source) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :metrics_batch_source_authorization}

  @doc """
  Publishes the batch of a fresh primary record, after checking its grant is still current. A
  grant that is not current, or an unknown source, refuses the record; a failed publish is an
  error, so the batch is redelivered. `opts[:request]` is passed to
  `ServiceRadar.NATS.JetStreamPublish.publish/3`.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %MetricBatch{} = batch, opts) do
    context = record.producer_context
    agent_id = context.origin_principal_id

    with {:ok, {family, producer_kind}} <- family(batch),
         :ok <-
           OutputGrants.check_current(
             Ecto.UUID.load!(context.producer_assignment_id),
             agent_id,
             record.output_contract.contract_id,
             Ecto.UUID.load!(record.network_scope_id),
             context.authority_epoch
           ) do
      event_id = Ecto.UUID.load!(record.event_id)
      attested = attest(batch, agent_id, producer_kind, event_id)
      publish_opts = [msg_id: event_id] ++ Keyword.take(opts, [:request])

      case JetStreamPublish.publish(
             subject(family, attested),
             MetricBatch.encode(attested),
             publish_opts
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, {:metrics_publish_failed, reason}}
      end
    else
      {:error, reason} when reason in [:output_grant_not_current, :metrics_batch_source] ->
        {:refused, reason}
    end
  end

  defp family(batch) do
    case Map.fetch(@families, source(batch)) do
      {:ok, family} -> {:ok, family}
      :error -> {:error, :metrics_batch_source}
    end
  end

  defp attest(batch, agent_id, producer_kind, event_id) do
    resource = batch.resource || %MetricResource{}
    identity = batch.ingest_identity || %IngestIdentity{}

    %{
      batch
      | resource: %{resource | agent_id: agent_id},
        ingest_identity: %{
          identity
          | payload_kind: @schema,
            producer_id: agent_id,
            producer_kind: producer_kind
        },
        ingress_id: event_id,
        ingress_timestamp_unix_nano: System.system_time(:nanosecond)
    }
  end

  defp source(%MetricBatch{ingest_identity: %IngestIdentity{source: source}}), do: source
  defp source(_batch), do: nil

  # Same subject the gateway derives: the family, then the first metric's type and name as
  # safe subject tokens.
  defp subject(family, %MetricBatch{metrics: [metric | _]}) do
    type = token(metric.metric_type) || "custom"
    name = token(metric.name) || "unknown"
    "metrics.#{family}.#{type}.#{name}"
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

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
