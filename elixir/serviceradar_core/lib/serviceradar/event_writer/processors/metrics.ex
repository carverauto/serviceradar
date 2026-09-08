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
  alias ServiceRadar.Inventory.DeviceSNMPFactWriter
  alias ServiceRadar.Observability.MetricEnvelope

  require Logger

  @impl true
  def table_name, do: "metrics"

  @impl true
  def process_batch(messages) do
    SignalTelemetry.emit(:metrics, :received, length(messages))

    {rows, rejected} = decode_batch(messages)
    rows = backfill_device_ids(rows)
    SignalTelemetry.emit(:metrics, :rejected, rejected)

    # Runs AFTER device_id backfill, because a fact is keyed by the canonical
    # device uid and an unresolved reading cannot be written at all. Deliberately
    # before the timeseries insert and deliberately unable to fail it: losing a
    # metric point is worse than losing a snapshot row the next poll rewrites.
    DeviceSNMPFactWriter.write_rows(rows)

    if rejected > 0 do
      Logger.warning("Metrics processor rejected non-protobuf metric messages", count: rejected)
    end

    # A non-numeric reading carries value 0.0 only so the protobuf point has a
    # shape at all. Writing it to timeseries_metrics would create a permanently
    # flat series for a version string and feed that to anomaly detection, so
    # the facts table above is the only place it lands.
    numeric_rows = Enum.filter(rows, &numeric_row?/1)

    with {:ok, count} <- Telemetry.insert_rows(numeric_rows) do
      SignalTelemetry.emit(:metrics, :written, count)
      {:ok, count}
    end
  rescue
    e ->
      Logger.error("Metrics batch processing failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Decodes a metric-envelope message batch and emits the per-batch decode
  telemetry, returning `{rows, rejected_count}`.

  This is the DB-free decode half of `process_batch/1`. Decode/completed and
  schema_version are emitted ONCE per `{source, schema_version}` group for the
  whole batch (replacing the old per-message pair of `:telemetry.execute` calls).
  Decode failures are still emitted per message from `parse_message/1`.
  """
  @spec decode_batch([map()]) :: {[map()], non_neg_integer()}
  def decode_batch(messages) do
    {rows, rejected, decode_stats} = build_rows(messages)
    emit_decode_telemetry(decode_stats)
    {rows, rejected}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    # Per-message decode WITHOUT per-message SUCCESS telemetry. Firing two
    # :telemetry.execute calls for every successfully decoded message dominated
    # EventWriter idle reductions (BatchProcessor_metrics/netflow ~1.05M reds/3s);
    # decode/completed + schema_version are now aggregated once per batch in
    # process_batch/1 (see emit_decode_telemetry/1). Decode *failures* stay
    # per-message — they are rare (a warning is logged when rejected > 0) and need
    # their per-failure source/reason tags.
    started_at = System.monotonic_time()

    case MetricEnvelope.decode_rows_count(data) do
      {:ok, rows, _count} ->
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
  @doc """
  Whether a decoded row carries a value the timeseries store can hold.

  Public so the split is testable without a database or a metric envelope.
  """
  @spec numeric_row?(map()) :: boolean()
  def numeric_row?(row), do: Map.get(row[:metadata] || %{}, "non_numeric") != "true"

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

  # Decodes the batch and accumulates per-batch decode telemetry stats grouped by
  # {source, schema_version} so the aggregated events keep accurate tags even when
  # a batch mixes sources/schemas. Duration is measured per message and summed per
  # group; one decode/completed + one schema_version event is emitted per group in
  # process_batch/1.
  defp build_rows(messages) do
    messages
    |> Enum.reduce({[], 0, %{}}, fn message, {timeseries, rejected, stats} ->
      started_at = System.monotonic_time()

      case parse_message(message) do
        rows when is_list(rows) ->
          duration = System.monotonic_time() - started_at
          stats = accumulate_decode_stats(stats, message, rows, length(rows), duration)
          {Enum.reverse(rows, timeseries), rejected, stats}

        _ ->
          {timeseries, rejected + 1, stats}
      end
    end)
    |> then(fn {timeseries, rejected, stats} ->
      {Enum.reverse(timeseries), rejected, stats}
    end)
  end

  defp accumulate_decode_stats(stats, %{metadata: metadata}, rows, row_count, duration) do
    key = {source(metadata), schema_version(rows)}

    Map.update(
      stats,
      key,
      %{count: 1, rows: row_count, duration: duration},
      fn acc ->
        %{
          count: acc.count + 1,
          rows: acc.rows + row_count,
          duration: acc.duration + duration
        }
      end
    )
  end

  defp accumulate_decode_stats(stats, _message, _rows, _row_count, _duration), do: stats

  # Per-batch decode telemetry. Emits ONE aggregated decode/completed and ONE
  # schema_version event per distinct {source, schema_version} group in the batch,
  # replacing the old per-message pair of :telemetry.execute calls.
  defp emit_decode_telemetry(stats) do
    Enum.each(stats, fn {{source, schema_version}, agg} ->
      :telemetry.execute(
        [:serviceradar, :metric_envelope, :decode, :completed],
        %{count: agg.count, rows: agg.rows, duration: agg.duration},
        %{source: source, schema_version: schema_version}
      )

      :telemetry.execute(
        [:serviceradar, :metric_envelope, :schema_version],
        %{count: agg.count},
        %{source: source, schema_version: schema_version}
      )
    end)

    :ok
  end

  defp subject(metadata) when is_map(metadata) do
    metadata[:base_subject] || metadata[:subject] || ""
  end

  defp subject(_metadata), do: ""

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
