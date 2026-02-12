defmodule ServiceRadar.ResultsRouter do
  @moduledoc """
  Routes push-result payloads from the agent gateway to the correct ingestors.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.Observability.IcmpMetricsIngestor
  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadar.Observability.SnmpMetricsIngestor
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
    service_name = status[:service_name] || "unknown"

    Logger.info(
      "ResultsRouter received: service_type=#{service_type} source=#{source} " <>
        "service=#{service_name}"
    )

    case process(status) do
      :ok ->
        ServiceStateRegistry.upsert_from_status(status)
        ServiceStatusPubSub.broadcast_update(status)

      {:ok, _result} ->
        ServiceStateRegistry.upsert_from_status(status)
        ServiceStatusPubSub.broadcast_update(status)

      {:error, reason} ->
        Logger.warning("Results processing failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp process(%{source: source, service_type: "sync"} = status)
       when source in ["results", :results] do
    handle_sync_results(status)
  end

  defp process(%{source: source, service_type: "sweep"} = status)
       when source in ["results", :results] do
    handle_sweep_results(status)
  end

  defp process(%{source: source, service_type: service_type} = status)
       when source in ["results", :results] and service_type in ["icmp", "ping"] do
    handle_icmp_results(status)
  end

  defp process(%{source: source, service_type: service_type} = status)
       when source in ["results", :results] and service_type in ["mapper", "mapper_discovery"] do
    handle_mapper_results(status)
  end

  defp process(%{source: source, service_type: "mapper_interfaces"} = status)
       when source in ["results", :results] do
    handle_mapper_interfaces(status)
  end

  defp process(%{source: source, service_type: "mapper_topology"} = status)
       when source in ["results", :results] do
    handle_mapper_topology(status)
  end

  defp process(%{source: source} = status) when source in ["sysmon-metrics", :sysmon_metrics] do
    handle_sysmon_metrics(status)
  end

  defp process(%{source: source} = status) when source in ["snmp-metrics", :snmp_metrics] do
    handle_snmp_metrics(status)
  end

  defp process(%{source: source} = status) when source in ["plugin-result", :plugin_result] do
    handle_plugin_results(status)
  end

  defp process(_status), do: :ok

  defp handle_sync_results(status) do
    # In schema-agnostic mode, DB schema is set by CNPG search_path
    schedule_sync_ingestion(status)
  end

  defp handle_mapper_results(status) do
    # Mapper results are device updates; use sync ingestion pipeline.
    MapperResultsIngestor.record_runs_from_payload(status[:message])
    schedule_sync_ingestion(status)
  end

  defp handle_mapper_interfaces(status) do
    MapperResultsIngestor.ingest_interfaces(status[:message], status)
  end

  defp handle_mapper_topology(status) do
    MapperResultsIngestor.ingest_topology(status[:message], status)
  end

  defp schedule_sync_ingestion(status) do
    message = status[:message]
    async_enabled = Application.get_env(:serviceradar_core, :sync_ingestor_async, true)

    if async_enabled do
      SyncIngestorQueue.enqueue(message)
    else
      SyncIngestorQueue.ingest_sync_results(message)
    end
  end

  defp handle_sweep_results(status) do
    # In schema-agnostic mode, DB schema is set by CNPG search_path
    with {:ok, payload} <- decode_payload(status[:message]),
         {:ok, results, execution_id, sweep_group_id} <- sweep_results(payload) do
      actor = SystemActor.system(:sweep_ingestor)
      expected_total_hosts = parse_total_hosts(payload)
      scanner_metrics = parse_scanner_metrics(payload)

      opts =
        [
          sweep_group_id: sweep_group_id,
          agent_id: status[:agent_id],
          actor: actor,
          expected_total_hosts: expected_total_hosts,
          scanner_metrics: scanner_metrics,
          chunk_index: status[:chunk_index],
          total_chunks: status[:total_chunks],
          is_final: status[:is_final]
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

      case sweep_ingestor().ingest_results(results, execution_id, opts) do
        :ok -> :ok
        {:ok, _stats} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_sysmon_metrics(status) do
    # In schema-agnostic mode, DB schema is set by CNPG search_path
    with {:ok, payload} <- decode_payload(status[:message]) do
      sysmon_ingestor().ingest(payload, status)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_snmp_metrics(status) do
    with {:ok, payload} <- decode_payload(status[:message]) do
      snmp_ingestor().ingest(payload, status)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_plugin_results(status) do
    with {:ok, payload} <- decode_payload(status[:message]) do
      plugin_ingestor().ingest(payload, status)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_icmp_results(status) do
    with {:ok, payload} <- decode_payload(status[:message]) do
      icmp_ingestor().ingest(payload, status)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(message) when is_binary(message) and byte_size(message) > 0 do
    Jason.decode(message)
  end

  defp decode_payload(_message), do: {:error, :empty_payload}

  defp sweep_results(%{"hosts" => hosts} = payload) when is_list(hosts) do
    sweep_group_id = parse_sweep_group_id(payload)
    last_sweep_time = parse_last_sweep(payload)
    execution_id = execution_id_from_payload(payload, sweep_group_id, last_sweep_time)
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

  defp sweep_results(_payload), do: {:error, :unsupported_payload}

  defp execution_id_from_payload(payload, sweep_group_id, last_sweep_time) do
    value = payload["execution_id"] || payload["executionId"]
    payload_id = normalize_uuid(value)
    deterministic_id = deterministic_execution_id(sweep_group_id, last_sweep_time)

    choose_execution_id(payload_id, deterministic_id)
  end

  defp choose_execution_id(payload_id, deterministic_id) do
    cond do
      mismatch_execution_id?(payload_id, deterministic_id) ->
        Logger.warning(
          "Sweep results execution_id mismatch; using deterministic execution id",
          payload_execution_id: payload_id,
          deterministic_execution_id: deterministic_id
        )

        deterministic_id

      missing_payload_id?(payload_id, deterministic_id) ->
        Logger.warning("Sweep results missing execution_id; using deterministic execution id")
        deterministic_id

      present_id?(payload_id) ->
        payload_id

      present_id?(deterministic_id) ->
        deterministic_id

      true ->
        Ash.UUID.generate()
    end
  end

  defp mismatch_execution_id?(payload_id, deterministic_id) do
    present_id?(payload_id) and present_id?(deterministic_id) and payload_id != deterministic_id
  end

  defp missing_payload_id?(payload_id, deterministic_id) do
    is_nil(payload_id) and present_id?(deterministic_id)
  end

  defp present_id?(value) when is_binary(value), do: value != ""
  defp present_id?(_value), do: false

  defp deterministic_execution_id(sweep_group_id, last_sweep_time)
       when is_binary(sweep_group_id) and sweep_group_id != "" and
              is_binary(last_sweep_time) and last_sweep_time != "" do
    hash = :crypto.hash(:md5, "#{sweep_group_id}:#{last_sweep_time}")

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
      Base.encode16(hash, case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  defp deterministic_execution_id(_sweep_group_id, _last_sweep_time), do: nil

  defp parse_sweep_group_id(payload) do
    value =
      payload["sweep_group_id"]

    normalize_uuid(value)
  end

  defp normalize_uuid(value) when is_binary(value) and value != "" do
    value
  end

  defp normalize_uuid(_value), do: nil

  defp parse_last_sweep(payload) do
    value =
      payload["last_sweep"]

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

  defp parse_total_hosts(payload) when is_map(payload) do
    payload
    |> Map.get("total_hosts")
    |> parse_integer()
  end

  defp parse_total_hosts(_payload), do: nil

  defp parse_scanner_metrics(payload) when is_map(payload) do
    value = payload["scanner_stats"]

    if is_map(value), do: value, else: nil
  end

  defp parse_scanner_metrics(_payload), do: nil

  defp build_sweep_result(host, last_sweep_time, network) when is_map(host) do
    with host_ip when is_binary(host_ip) and host_ip != "" <- host_ip(host) do
      icmp_status = icmp_status(host)
      canonical_port_results = build_port_scan_results(port_results(host))

      base = %{
        "host_ip" => host_ip,
        "hostname" => host["hostname"],
        "available" => host_available(host, icmp_status),
        "icmp_available" => icmp_available(host, icmp_status),
        "icmp_response_time_ns" => icmp_response_time_ns(host, icmp_status),
        "icmp_packet_loss" => icmp_packet_loss(icmp_status),
        "port_results" => canonical_port_results,
        "error" => host["error"],
        "last_sweep_time" => last_sweep_time
      }

      maybe_put_network(base, network)
    else
      _ -> nil
    end
  end

  defp build_sweep_result(_host, _last_sweep_time, _network), do: nil

  defp host_ip(host) do
    value = host["host"]

    if is_binary(value) and value != "" do
      value
    end
  end

  defp port_results(host) when is_map(host), do: host["port_results"] || []

  defp port_results(_host), do: []

  defp icmp_status(host) do
    status = host["icmp_status"]

    if is_map(status) and map_size(status) > 0 do
      status
    end
  end

  defp icmp_available(host, icmp_status) do
    if icmp_status do
      icmp_status["available"] || false
    else
      host["available"] || false
    end
  end

  defp host_available(host, icmp_status) do
    case host["available"] do
      value when is_boolean(value) -> value
      _ -> icmp_available(host, icmp_status)
    end
  end

  defp icmp_response_time_ns(host, icmp_status) do
    (icmp_status &&
       parse_duration_ns(icmp_status["round_trip"])) ||
      parse_duration_ns(host["response_time"])
  end

  defp icmp_packet_loss(icmp_status) do
    if icmp_status do
      icmp_status["packet_loss"]
    end
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
          "available" => result["available"] || false,
          "response_time_ns" => parse_duration_ns(result["response_time"])
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

  defp snmp_ingestor do
    Application.get_env(:serviceradar_core, :snmp_metrics_ingestor, SnmpMetricsIngestor)
  end

  defp icmp_ingestor do
    Application.get_env(:serviceradar_core, :icmp_metrics_ingestor, IcmpMetricsIngestor)
  end

  defp plugin_ingestor do
    Application.get_env(:serviceradar_core, :plugin_result_ingestor, PluginResultIngestor)
  end
end
