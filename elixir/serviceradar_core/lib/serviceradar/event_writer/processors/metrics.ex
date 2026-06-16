defmodule ServiceRadar.EventWriter.Processors.Metrics do
  @moduledoc """
  Processor for the dedicated high-rate `metrics.>` stream.

  Non-OTLP metrics use ServiceRadar's canonical protobuf metric envelope. Sysmon,
  SNMP, ICMP, MTR, sweep, rperf, plugin, native add-on, and custom scalar metrics
  are decoded once and persisted through the generic timeseries processor.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.Telemetry
  alias ServiceRadar.EventWriter.SignalTelemetry
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Observability.MetricEnvelope

  require Logger

  @impl true
  def table_name, do: "metrics"

  @impl true
  def process_batch(messages) do
    SignalTelemetry.emit(:metrics, :received, length(messages))

    {rows, rejected} = build_rows(messages)
    rows = backfill_device_ids(rows)
    SignalTelemetry.emit(:metrics, :rejected, rejected)

    if rejected > 0 do
      Logger.warning("Metrics processor rejected non-protobuf metric messages", count: rejected)
    end

    with {:ok, count} <- Telemetry.insert_rows(rows) do
      SignalTelemetry.emit(:metrics, :written, count)
      {:ok, count}
    end
  rescue
    e ->
      Logger.error("Metrics batch processing failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    started_at = System.monotonic_time()

    case MetricEnvelope.decode_rows_count(data) do
      {:ok, rows, count} ->
        emit_decode_completed(rows, count, metadata, started_at)
        rows

      {:error, reason} ->
        emit_decode_failed(reason, metadata, started_at)

        Logger.debug("Failed to parse metric protobuf envelope",
          reason: inspect(reason),
          subject: subject(metadata)
        )

        nil
    end
  end

  # Canonical device_id enrichment for the DB-sync persistence path (the deleted
  # legacy ingestors did this). Resolution is batched once per message batch and
  # is strictly best-effort: an unknown IP or a lookup failure leaves device_id
  # nil rather than dropping the metric. The anomaly hot path is unaffected — it
  # never calls this; only the CNPG persistence path enriches device_id.
  defp backfill_device_ids(rows) do
    ips =
      rows
      |> Enum.filter(fn row -> is_nil(row[:device_id]) and is_binary(row[:target_device_ip]) end)
      |> Enum.map(& &1[:target_device_ip])
      |> Enum.uniq()

    case ips do
      [] ->
        rows

      ips ->
        resolved = resolve_device_ids(ips)

        Enum.map(rows, fn row ->
          case {row[:device_id], Map.get(resolved, row[:target_device_ip])} do
            {nil, device_id} when is_binary(device_id) -> %{row | device_id: device_id}
            _ -> row
          end
        end)
    end
  end

  defp resolve_device_ids(ips) do
    actor = SystemActor.system(:metric_envelope_ingestor)

    ips
    |> DeviceLookup.batch_lookup_by_ip(actor: actor, include_deleted: true)
    |> Enum.reduce(%{}, fn
      {ip, %{canonical_device_id: device_id}}, acc
      when is_binary(device_id) and device_id != "" ->
        Map.put(acc, ip, device_id)

      _entry, acc ->
        acc
    end)
  rescue
    error ->
      Logger.debug("metric device_id resolution failed", error: inspect(error))
      %{}
  end

  defp build_rows(messages) do
    messages
    |> Enum.reduce({[], 0}, fn message, {timeseries, rejected} ->
      case parse_message(message) do
        rows when is_list(rows) ->
          {Enum.reverse(rows, timeseries), rejected}

        _ ->
          {timeseries, rejected + 1}
      end
    end)
    |> then(fn {timeseries, rejected} ->
      {Enum.reverse(timeseries), rejected}
    end)
  end

  defp subject(metadata) when is_map(metadata) do
    metadata[:base_subject] || metadata[:subject] || ""
  end

  defp subject(_metadata), do: ""

  defp emit_decode_completed(rows, row_count, metadata, started_at) do
    duration = System.monotonic_time() - started_at
    schema_version = schema_version(rows)

    :telemetry.execute(
      [:serviceradar, :metric_envelope, :decode, :completed],
      %{count: 1, rows: row_count, duration: duration},
      %{
        subject: subject(metadata),
        source: source(metadata),
        schema_version: schema_version
      }
    )

    :telemetry.execute(
      [:serviceradar, :metric_envelope, :schema_version],
      %{count: 1},
      %{source: source(metadata), schema_version: schema_version}
    )

    :ok
  end

  defp emit_decode_failed(reason, metadata, started_at) do
    :telemetry.execute(
      [:serviceradar, :metric_envelope, :decode, :failed],
      %{count: 1, duration: System.monotonic_time() - started_at},
      %{
        subject: subject(metadata),
        source: source(metadata),
        reason: reason_tag(reason)
      }
    )

    :ok
  end

  defp schema_version([%{metadata: %{} = metadata} | _]) do
    Map.get(metadata, "schema") || Map.get(metadata, :schema) || "unknown"
  end

  defp schema_version(_rows), do: "unknown"

  defp source(metadata) when is_map(metadata) do
    metadata[:source] || metadata["source"] || subject(metadata) || "unknown"
  end

  defp source(_metadata), do: "unknown"

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(%module{}), do: module
end
