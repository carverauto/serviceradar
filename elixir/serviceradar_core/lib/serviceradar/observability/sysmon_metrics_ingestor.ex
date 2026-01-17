defmodule ServiceRadar.Observability.SysmonMetricsIngestor do
  @moduledoc """
  Parses sysmon metric payloads and ingests them into hypertables.

  In schema-agnostic mode, operates as a single instance since the DB schema
  is set by CNPG search_path credentials.
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent

  alias ServiceRadar.Observability.{
    CpuClusterMetric,
    CpuMetric,
    DiskMetric,
    MemoryMetric,
    ProcessMetric
  }

  @spec ingest(map(), map()) :: :ok | {:error, term()}
  def ingest(payload, status) when is_map(payload) and is_map(status) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:sysmon_metrics_ingestor)

    with {:ok, sample} <- extract_sample(payload),
         {:ok, context} <- build_context(sample, status, actor) do
      metrics = build_metrics(sample, context)
      persist_metrics(metrics, actor)
    end
  end

  def ingest(_payload, _status), do: {:error, :invalid_payload}

  @doc false
  def build_metrics(sample, context) when is_map(sample) and is_map(context) do
    created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    base = %{
      timestamp: context.timestamp,
      gateway_id: context.gateway_id,
      agent_id: context.agent_id,
      host_id: context.host_id,
      device_id: context.device_id,
      partition: context.partition,
      created_at: created_at
    }

    %{
      cpu: build_cpu_records(fetch_list(sample, "cpus"), base),
      cpu_clusters: build_cluster_records(fetch_list(sample, "clusters"), base),
      memory: build_memory_records(fetch_map(sample, "memory"), base),
      disks: build_disk_records(fetch_list(sample, "disks"), base),
      processes: build_process_records(fetch_list(sample, "processes"), base)
    }
  end

  defp extract_sample(payload) do
    case fetch_map(payload, "status") do
      nil -> {:error, :missing_status}
      sample -> {:ok, sample}
    end
  end

  defp build_context(sample, status, actor) do
    gateway_id = status[:gateway_id]
    agent_id = status[:agent_id] || fetch_string(sample, "agent_id")
    partition = status[:partition] || fetch_string(sample, "partition")
    host_id = fetch_string(sample, "host_id")
    timestamp = parse_timestamp(fetch_value(sample, "timestamp"))
    device_id = resolve_device_id(agent_id, actor)

    if is_binary(gateway_id) and gateway_id != "" do
      {:ok,
       %{
         gateway_id: gateway_id,
         agent_id: agent_id,
         host_id: host_id,
         partition: partition,
         timestamp: timestamp,
         device_id: device_id
       }}
    else
      {:error, :missing_gateway_id}
    end
  end

  defp resolve_device_id(nil, _actor), do: nil
  defp resolve_device_id("", _actor), do: nil

  defp resolve_device_id(agent_id, actor) do
    # DB connection's search_path determines the schema
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, agent} ->
        agent.device_uid

      {:error, reason} ->
        Logger.debug("SysmonMetricsIngestor: agent lookup failed: #{inspect(reason)}")
        nil
    end
  end

  defp build_cpu_records(cpus, base) do
    Enum.reduce(cpus, [], fn cpu, acc ->
      core_id = parse_integer(fetch_value(cpu, "core_id"))
      usage_percent = parse_float(fetch_value(cpu, "usage_percent"))
      frequency_hz = parse_float(fetch_value(cpu, "frequency_hz"))
      label = fetch_string(cpu, "label")
      cluster = fetch_string(cpu, "cluster")

      record =
        base
        |> Map.put(:core_id, core_id)
        |> Map.put(:usage_percent, usage_percent)
        |> Map.put(:frequency_hz, frequency_hz)
        |> Map.put(:label, label)
        |> Map.put(:cluster, cluster)

      [record | acc]
    end)
    |> Enum.reverse()
  end

  defp build_cluster_records(clusters, base) do
    Enum.reduce(clusters, [], fn cluster, acc ->
      name = fetch_string(cluster, "name")
      frequency_hz = parse_float(fetch_value(cluster, "frequency_hz"))

      if name do
        record =
          base
          |> Map.put(:cluster, name)
          |> Map.put(:frequency_hz, frequency_hz)

        [record | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp build_memory_records(nil, _base), do: []

  defp build_memory_records(memory, base) do
    total_bytes = parse_integer(fetch_value(memory, "total_bytes"))
    used_bytes = parse_integer(fetch_value(memory, "used_bytes"))
    available_bytes = available_bytes(total_bytes, used_bytes)
    usage_percent = usage_percent(used_bytes, total_bytes)

    [
      base
      |> Map.put(:total_bytes, total_bytes)
      |> Map.put(:used_bytes, used_bytes)
      |> Map.put(:available_bytes, available_bytes)
      |> Map.put(:usage_percent, usage_percent)
    ]
  end

  defp build_disk_records(disks, base) do
    Enum.reduce(disks, [], fn disk, acc ->
      mount_point = fetch_string(disk, "mount_point")
      total_bytes = parse_integer(fetch_value(disk, "total_bytes"))
      used_bytes = parse_integer(fetch_value(disk, "used_bytes"))
      available_bytes = available_bytes(total_bytes, used_bytes)
      usage_percent = usage_percent(used_bytes, total_bytes)

      if mount_point do
        record =
          base
          |> Map.put(:mount_point, mount_point)
          |> Map.put(:device_name, fetch_string(disk, "device_name"))
          |> Map.put(:total_bytes, total_bytes)
          |> Map.put(:used_bytes, used_bytes)
          |> Map.put(:available_bytes, available_bytes)
          |> Map.put(:usage_percent, usage_percent)

        [record | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp build_process_records(processes, base) do
    Enum.reduce(processes, [], fn process, acc ->
      pid = parse_integer(fetch_value(process, "pid"))

      if pid do
        record =
          base
          |> Map.put(:pid, pid)
          |> Map.put(:name, fetch_string(process, "name"))
          |> Map.put(:cpu_usage, parse_float(fetch_value(process, "cpu_usage")))
          |> Map.put(:memory_usage, parse_integer(fetch_value(process, "memory_usage")))
          |> Map.put(:status, fetch_string(process, "status"))
          |> Map.put(:start_time, fetch_string(process, "start_time"))

        [record | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp persist_metrics(metrics, actor) do
    # DB connection's search_path determines the schema
    results = [
      insert_bulk(metrics.cpu, CpuMetric, actor),
      insert_bulk(metrics.cpu_clusters, CpuClusterMetric, actor),
      insert_bulk(metrics.memory, MemoryMetric, actor),
      insert_bulk(metrics.disks, DiskMetric, actor),
      insert_bulk(metrics.processes, ProcessMetric, actor)
    ]

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_bulk([], _resource, _actor), do: :ok

  defp insert_bulk(records, resource, actor) do
    case Ash.bulk_create(records, resource, :create,
           actor: actor,
           return_errors?: true,
           stop_on_error?: false
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.warning(
          "SysmonMetricsIngestor: failed to insert #{inspect(resource)}: #{inspect(errors)}"
        )

        {:error, errors}

      {:error, reason} ->
        Logger.warning(
          "SysmonMetricsIngestor: failed to insert #{inspect(resource)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp parse_timestamp(_value), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp fetch_value(map, key) when is_map(map) do
    Map.get(map, key) ||
      if is_binary(key) do
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
      end
  end

  defp fetch_value(_map, _key), do: nil

  defp fetch_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp fetch_list(map, key) do
    case fetch_value(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp fetch_map(map, key) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(value) when is_float(value), do: trunc(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_float(_value), do: nil

  defp available_bytes(nil, _used), do: nil
  defp available_bytes(_total, nil), do: nil

  defp available_bytes(total, used)
       when is_integer(total) and is_integer(used) and total >= used do
    total - used
  end

  defp available_bytes(_total, _used), do: nil

  defp usage_percent(nil, _total), do: nil
  defp usage_percent(_used, nil), do: nil

  defp usage_percent(used, total) when total > 0 do
    used / total * 100.0
  end

  defp usage_percent(_used, _total), do: nil
end
