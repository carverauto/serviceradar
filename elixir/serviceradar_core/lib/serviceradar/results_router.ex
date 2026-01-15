defmodule ServiceRadar.ResultsRouter do
  @moduledoc """
  Routes push-result payloads from the agent gateway to the correct ingestors.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias ServiceRadar.Observability.SysmonMetricsIngestor
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  @duration_regex ~r/(\d+(?:\.\d+)?)(ns|us|µs|μs|ms|s|m|h)/

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("ResultsRouter started on node #{Node.self()}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:results_update, status}, state) do
    service_type = status[:service_type] || "unknown"
    source = status[:source] || "unknown"
    tenant_id = status[:tenant_id] || "unknown"
    service_name = status[:service_name] || "unknown"

    Logger.info(
      "ResultsRouter received: service_type=#{service_type} source=#{source} " <>
        "tenant=#{tenant_id} service=#{service_name}"
    )

    case process(status) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("Results processing failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp process(%{source: source} = status) when source in ["results", :results] do
    case status[:service_type] do
      "sync" -> handle_sync_results(status)
      "sweep" -> handle_sweep_results(status)
      _ -> :ok
    end
  end

  defp process(%{source: source} = status) when source in ["sysmon-metrics", :sysmon_metrics] do
    handle_sysmon_metrics(status)
  end

  defp process(_status), do: :ok

  defp handle_sync_results(status) do
    tenant_id = status[:tenant_id]

    if is_binary(tenant_id) and tenant_id != "" do
      schedule_sync_ingestion(status, tenant_id)
    else
      {:error, :missing_tenant_id}
    end
  end

  defp schedule_sync_ingestion(status, tenant_id) do
    message = status[:message]
    async_enabled = Application.get_env(:serviceradar_core, :sync_ingestor_async, true)

    if async_enabled do
      SyncIngestorQueue.enqueue(message, tenant_id)
    else
      SyncIngestorQueue.ingest_sync_results(message, tenant_id)
    end
  end

  defp handle_sweep_results(status) do
    tenant_id = status[:tenant_id]

    if is_binary(tenant_id) and tenant_id != "" do
      with {:ok, payload} <- decode_payload(status[:message]),
           {:ok, results, execution_id, sweep_group_id} <- sweep_results(payload) do
        # Simple actor - DB connection's search_path determines the schema
        actor = SystemActor.system(:sweep_ingestor)

        opts =
          [
            sweep_group_id: sweep_group_id,
            agent_id: status[:agent_id],
            actor: actor
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

        case sweep_ingestor().ingest_results(results, execution_id, tenant_id, opts) do
          :ok -> :ok
          {:ok, _stats} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_tenant_id}
    end
  end

  defp handle_sysmon_metrics(status) do
    tenant_id = status[:tenant_id]

    if is_binary(tenant_id) and tenant_id != "" do
      with {:ok, payload} <- decode_payload(status[:message]) do
        sysmon_ingestor().ingest(payload, status, tenant_id)
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_tenant_id}
    end
  end

  defp decode_payload(message) when is_binary(message) and byte_size(message) > 0 do
    Jason.decode(message)
  end

  defp decode_payload(_message), do: {:error, :empty_payload}

  defp sweep_results(%{"hosts" => hosts} = payload) when is_list(hosts) do
    execution_id = parse_execution_id(payload)
    sweep_group_id = parse_sweep_group_id(payload)
    last_sweep_time = parse_last_sweep(payload)
    network = payload["network"] || payload["network_cidr"] || payload["networkCidr"]

    results =
      hosts
      |> Enum.map(&build_sweep_result(&1, last_sweep_time, network))
      |> Enum.reject(&is_nil/1)

    if results == [] do
      {:error, :no_hosts}
    else
      {:ok, results, execution_id, sweep_group_id}
    end
  end

  defp sweep_results(results) when is_list(results) do
    execution_id =
      results
      |> List.first()
      |> case do
        nil -> nil
        first -> first["execution_id"] || first["executionId"]
      end
      |> normalize_uuid()

    execution_id =
      if execution_id == nil do
        Ash.UUID.generate()
      else
        execution_id
      end

    sweep_group_id =
      results
      |> List.first()
      |> case do
        nil -> nil
        first -> first["sweep_group_id"] || first["sweepGroupId"]
      end
      |> normalize_uuid()

    {:ok, results, execution_id, sweep_group_id}
  end

  defp sweep_results(_payload), do: {:error, :unsupported_payload}

  defp parse_execution_id(payload) do
    value =
      payload["execution_id"] ||
        payload["executionId"]

    case normalize_uuid(value) do
      nil -> Ash.UUID.generate()
      normalized -> normalized
    end
  end

  defp parse_sweep_group_id(payload) do
    value =
      payload["sweep_group_id"] ||
        payload["sweepGroupId"]

    normalize_uuid(value)
  end

  defp normalize_uuid(value) when is_binary(value) and value != "" do
    value
  end

  defp normalize_uuid(_value), do: nil

  defp parse_last_sweep(payload) do
    value =
      payload["last_sweep"] ||
        payload["lastSweep"]

    parse_time(value)
  end

  defp parse_time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp parse_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} ->
        parse_time(parsed)

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> DateTime.to_iso8601(dt)
          _ -> nil
        end
    end
  end

  defp parse_time(_value), do: nil

  defp build_sweep_result(host, last_sweep_time, network) when is_map(host) do
    with host_ip when is_binary(host_ip) and host_ip != "" <- host_ip(host) do
      icmp_status = icmp_status(host)
      port_scan_results = build_port_scan_results(port_results(host))

      base = %{
        "host_ip" => host_ip,
        "hostname" => host["hostname"],
        "icmp_available" => icmp_available(host, icmp_status),
        "icmp_response_time_ns" => icmp_response_time_ns(host, icmp_status),
        "icmp_packet_loss" => icmp_packet_loss(icmp_status),
        "tcp_ports_open" => open_ports(port_scan_results),
        "port_scan_results" => port_scan_results,
        "last_sweep_time" => last_sweep_time
      }

      maybe_put_network(base, network)
    else
      _ -> nil
    end
  end

  defp build_sweep_result(_host, _last_sweep_time, _network), do: nil

  defp host_ip(host) do
    value = host["host"] || host["host_ip"] || host["hostIp"] || host["ip"]

    if is_binary(value) and value != "" do
      value
    end
  end

  defp port_results(host), do: host["port_results"] || host["portResults"] || []

  defp icmp_status(host) do
    status = host["icmp_status"] || host["icmpStatus"]

    if is_map(status) and map_size(status) > 0 do
      status
    end
  end

  defp icmp_available(host, icmp_status) do
    if icmp_status do
      icmp_status["available"] || icmp_status[:available] || false
    else
      host["available"] || host[:available] || false
    end
  end

  defp icmp_response_time_ns(host, icmp_status) do
    (icmp_status &&
       parse_duration_ns(icmp_status["round_trip"] || icmp_status["roundTrip"])) ||
      parse_duration_ns(host["response_time"] || host["responseTime"])
  end

  defp icmp_packet_loss(icmp_status) do
    if icmp_status do
      icmp_status["packet_loss"] || icmp_status["packetLoss"]
    end
  end

  defp open_ports(port_scan_results) do
    port_scan_results
    |> Enum.filter(& &1["available"])
    |> Enum.map(& &1["port"])
  end

  defp maybe_put_network(base, network) do
    if is_binary(network) and network != "" do
      Map.put(base, "network_cidr", network)
    else
      base
    end
  end

  defp build_port_scan_results(port_results) do
    port_results
    |> List.wrap()
    |> Enum.reduce([], fn result, acc ->
      port = parse_integer(result["port"] || result[:port])

      if port do
        entry = %{
          "port" => port,
          "available" => result["available"] || result[:available] || false,
          "response_time_ns" =>
            parse_duration_ns(
              result["response_time"] || result["responseTime"] || result[:response_time]
            )
        }

        [entry | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_duration_ns(value) when is_integer(value) and value >= 0, do: value
  defp parse_duration_ns(value) when is_float(value) and value >= 0, do: trunc(value)

  defp parse_duration_ns(value) when is_binary(value) do
    normalized = String.replace(value, ["µ", "μ"], "u")

    case Regex.scan(@duration_regex, normalized) do
      [] ->
        case Integer.parse(normalized) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      matches ->
        total =
          Enum.reduce(matches, 0, fn [_, number, unit], acc ->
            with {value, ""} <- Float.parse(number),
                 multiplier when is_integer(multiplier) <- duration_multiplier(unit) do
              acc + trunc(value * multiplier)
            else
              _ -> acc
            end
          end)

        if total > 0 do
          total
        else
          nil
        end
    end
  end

  defp parse_duration_ns(_value), do: nil

  defp duration_multiplier("ns"), do: 1
  defp duration_multiplier("us"), do: 1_000
  defp duration_multiplier("ms"), do: 1_000_000
  defp duration_multiplier("s"), do: 1_000_000_000
  defp duration_multiplier("m"), do: 60 * 1_000_000_000
  defp duration_multiplier("h"), do: 3_600 * 1_000_000_000
  defp duration_multiplier(_), do: nil

  defp parse_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp sweep_ingestor do
    Application.get_env(:serviceradar_core, :sweep_ingestor, SweepResultsIngestor)
  end

  defp sysmon_ingestor do
    Application.get_env(:serviceradar_core, :sysmon_metrics_ingestor, SysmonMetricsIngestor)
  end
end
