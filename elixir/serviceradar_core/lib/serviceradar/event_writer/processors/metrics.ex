defmodule ServiceRadar.EventWriter.Processors.Metrics do
  @moduledoc """
  Processor for the dedicated high-rate `metrics.>` stream.

  Sysmon messages are family envelopes emitted by the agent gateway and are
  persisted through the shared hypertable ingestor.
  SNMP interface metric messages are flat scalar telemetry records and continue
  through the generic timeseries processor.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.Processors.Telemetry
  alias ServiceRadar.Observability.SysmonMetricsIngestor

  require Logger

  @sysmon_schema "serviceradar.sysmon.metrics.v1"
  @legacy_sysmon_schema "serviceradar.sysmon.shadow.v1"
  @snmp_schema "serviceradar.snmp.interface_metric.v1"

  @impl true
  def table_name, do: "metrics"

  @impl true
  def process_batch(messages) do
    {sysmon_messages, snmp_messages, rejected} = partition_messages(messages)

    if rejected > 0 do
      Logger.debug("Metrics processor rejected unsupported messages", count: rejected)
    end

    with :ok <- ingest_sysmon_messages(sysmon_messages),
         {:ok, snmp_count} <- Telemetry.process_batch(snmp_messages) do
      {:ok, length(sysmon_messages) + snmp_count}
    end
  rescue
    e ->
      Logger.error("Metrics batch processing failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    with {:ok, json} <- Jason.decode(data),
         {:ok, kind} <- metric_kind(json, metadata) do
      case kind do
        :sysmon -> parse_sysmon(json, metadata)
        :snmp -> Telemetry.parse_message(%{data: data, metadata: metadata})
      end
    else
      _ -> nil
    end
  end

  @doc false
  def parse_sysmon(json, metadata) do
    with %{} = sample <- Map.get(json, "sample"),
         family when family in ["cpu", "memory", "disk", "process"] <-
           sysmon_family(json, metadata),
         filtered_sample when is_map(filtered_sample) <- filter_sysmon_sample(sample, family) do
      %{
        payload: %{"status" => filtered_sample},
        status: status_from_envelope(json),
        family: family
      }
    else
      _ -> nil
    end
  end

  @doc false
  def filter_sysmon_sample(sample, family) when family in ["cpu", "memory", "disk", "process"] do
    base =
      Map.take(sample, [
        "timestamp",
        "host_id",
        "host_ip",
        "agent_id",
        "partition"
      ])

    case family do
      "cpu" ->
        base
        |> maybe_put("cpus", list_or_empty(sample["cpus"]))
        |> maybe_put("clusters", list_or_empty(sample["clusters"]))

      "memory" ->
        maybe_put(base, "memory", map_or_nil(sample["memory"]))

      "disk" ->
        maybe_put(base, "disks", list_or_empty(sample["disks"]))

      "process" ->
        maybe_put(base, "processes", list_or_empty(sample["processes"]))
    end
  end

  def filter_sysmon_sample(_sample, _family), do: nil

  defp partition_messages(messages) do
    messages
    |> Enum.reduce({[], [], 0}, fn message, {sysmon, snmp, rejected} ->
      case parse_message(message) do
        %{payload: _payload, status: _status} = parsed ->
          {[parsed | sysmon], snmp, rejected}

        row when is_map(row) ->
          {sysmon, [message | snmp], rejected}

        _ ->
          {sysmon, snmp, rejected + 1}
      end
    end)
    |> then(fn {sysmon, snmp, rejected} ->
      {Enum.reverse(sysmon), Enum.reverse(snmp), rejected}
    end)
  end

  defp ingest_sysmon_messages(sysmon_messages) do
    Enum.reduce_while(sysmon_messages, :ok, fn %{payload: payload, status: status}, :ok ->
      case sysmon_ingestor().ingest(payload, status) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sysmon_ingestor do
    Application.get_env(:serviceradar_core, :metrics_sysmon_ingestor, SysmonMetricsIngestor)
  end

  defp metric_kind(json, metadata) do
    subject = subject(metadata)
    schema = Map.get(json, "schema")

    cond do
      schema in [@sysmon_schema, @legacy_sysmon_schema] or
          String.starts_with?(subject, "metrics.sysmon.") ->
        {:ok, :sysmon}

      schema == @snmp_schema or String.starts_with?(subject, "metrics.snmp.") ->
        {:ok, :snmp}

      true ->
        :error
    end
  end

  defp sysmon_family(json, metadata) do
    Map.get(json, "metric_family") || metadata |> subject() |> String.split(".") |> List.last()
  end

  defp status_from_envelope(json) do
    %{
      service_name: Map.get(json, "service_name") || "sysmon",
      service_type: Map.get(json, "service_type") || "sysmon",
      source: Map.get(json, "source") || "sysmon-metrics",
      agent_id: Map.get(json, "agent_id"),
      gateway_id: Map.get(json, "gateway_id"),
      partition: Map.get(json, "partition"),
      timestamp: Map.get(json, "status_timestamp_unix_nano"),
      agent_timestamp: Map.get(json, "agent_timestamp_unix_nano")
    }
  end

  defp subject(metadata) when is_map(metadata) do
    metadata[:base_subject] || metadata[:subject] || ""
  end

  defp subject(_metadata), do: ""

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
