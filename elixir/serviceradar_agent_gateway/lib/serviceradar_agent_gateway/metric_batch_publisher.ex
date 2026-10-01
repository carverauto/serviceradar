defmodule ServiceRadarAgentGateway.MetricBatchPublisher do
  @moduledoc """
  Publishes one attested protobuf `MetricBatch` to NATS under the server's
  max_payload.

  An oversized publish is rejected by the broker with "Maximum Payload
  Violation" and the server closes the gateway's shared NATS connection, so
  every metric publisher routes through here: batches whose encoded size
  exceeds the limit are split into several under-limit messages (see
  `ServiceRadarAgentGateway.MetricBatchSplit`), preserving the batch
  envelope and attestation on each part and keeping the subject derived from
  the original batch's first metric so routing is identical to an unsplit
  publish.
  """

  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadar.NATS.Connection
  alias ServiceRadarAgentGateway.IngressId
  alias ServiceRadarAgentGateway.MetricBatchSplit

  require Logger

  # NATS server default max_payload when the broker advertises nothing usable.
  @default_server_max_payload 1_048_576

  # HPUB publishes count the NATS header block (NATS/1.0 line, ingress
  # identity headers, trace context) against max_payload, so the publish
  # budget keeps headroom for headers and protocol slack below the
  # advertised limit. Scales down for clusters configured below the
  # margin so a small max_payload never collapses the budget to zero.
  @max_payload_safety_margin 64 * 1024

  @type publish_result :: :ok | {:error, term()}

  @doc """
  Publishes `batch` to the configured connection, splitting it first so no
  single NATS message exceeds the server's max_payload.

  `opts[:subject]` is the subject derived from the original batch under
  `opts[:default_subject_prefix]`; every part is published under it (after
  the configured `:subject_prefix` rewrite). `status` carries the
  agent/gateway identity used in the split warning; `opts[:log_label]`
  names the metric type in that warning.
  """
  @spec publish(MetricBatch.t(), map(), map(), keyword(), keyword()) :: publish_result()
  def publish(%MetricBatch{} = batch, ingress_context, status, config, opts) do
    connection = Keyword.get(config, :connection, Connection)
    max_payload = advertised_max_payload(connection)

    split = MetricBatchSplit.split(batch, publish_budget(max_payload))
    log_split(split, max_payload, status, opts)

    case split.parts do
      [] ->
        {:error, {:metric_batch_exceeds_max_payload, split.original_bytes, max_payload}}

      parts ->
        publish_parts(Keyword.fetch!(opts, :subject), parts, ingress_context, config, opts)
    end
  end

  defp publish_parts(subject, parts, ingress_context, config, opts) do
    message_id =
      ingress_context[:nats_msg_id] || ingress_context[:message_id] ||
        ingress_context[:event_id] || ingress_context[:ingress_id]

    split? = length(parts) > 1

    parts
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {part, index}, :ok ->
      part_context =
        if split? do
          Map.put(ingress_context, :nats_msg_id, "#{message_id}:part:#{index}")
        else
          ingress_context
        end

      case publish_message(subject, MetricBatch.encode(part), part_context, config, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The connection module may not export max_payload/0 and the INFO query
  # can race a reconnect; both fall back to the NATS server default.
  defp advertised_max_payload(connection) do
    connection.max_payload()
  rescue
    _ -> @default_server_max_payload
  catch
    :exit, _ -> @default_server_max_payload
  end

  defp publish_budget(max_payload) do
    margin = min(@max_payload_safety_margin, div(max_payload, 8))
    max_payload - margin
  end

  # A specific warning for a split (or a limit so tight that points were
  # dropped) instead of relying on the broker's connection-killing error.
  defp log_split(%{parts: [_part], dropped_points: 0}, _max_payload, _status, _opts), do: :ok

  defp log_split(%{parts: parts, original_bytes: bytes, dropped_points: dropped}, max_payload, status, opts) do
    log_label = Keyword.get(opts, :log_label, "metric")

    Logger.warning("Split oversized #{log_label} metric batch for NATS max_payload",
      bytes: bytes,
      limit_bytes: max_payload,
      parts: length(parts),
      dropped_points: dropped,
      agent_id: status[:agent_id],
      gateway_id: status[:gateway_id],
      partition: status[:partition]
    )
  end

  defp publish_message(subject, payload, ingress_context, config, opts) do
    connection = Keyword.get(config, :connection, Connection)
    default_subject_prefix = Keyword.fetch!(opts, :default_subject_prefix)
    subject_prefix = Keyword.get(config, :subject_prefix, default_subject_prefix)
    configured_headers = Keyword.get(config, :headers, [])
    subject = String.replace_prefix(subject, default_subject_prefix, subject_prefix)
    headers = configured_headers ++ IngressId.headers(ingress_context)

    case connection.publish(subject, payload, headers: headers) do
      :ok -> :ok
      {:error, reason} -> {:error, {:publish_failed, [{subject, reason}]}}
    end
  end
end
