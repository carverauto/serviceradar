defmodule ServiceRadar.ResultsRouter do
  @moduledoc """
  Routes push-result payloads from the agent gateway to the correct ingestors.

  ## Async batching

  The async (`cast`) path buffers `{:results_update, status}` payloads and flushes
  on a timer or when the buffer fills, whichever comes first. On flush, each
  status still runs its type-specific `process/2` handler individually (sweep,
  sync, mapper, etc. are unchanged), but the service-state publish is collapsed
  into ONE `ServiceStateRegistry.bulk_upsert_from_statuses/1` plus ONE
  `ServiceStatusPubSub.broadcast_batch/1` for the whole flush. This removes the
  per-status upsert + PubSub overhead that dominated idle ResultsRouter
  reductions (~704k reds/3s).

  Synchronous (`call`) paths stay per-item and immediate — they need a reply.

  Configure with app env (defaults shown):

      config :serviceradar_core,
        results_router_batching: true,
        results_router_flush_interval_ms: 250,
        results_router_max_buffer: 200
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.BumblebeeIngestor
  alias ServiceRadar.Inventory.EndpointInventoryIngestor
  alias ServiceRadar.Inventory.EndpointInventoryIngestorQueue
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  require Logger

  @duration_regex ~r/(\d+(?:\.\d+)?)(ns|us|µs|μs|ms|s|m|h)/

  @default_flush_interval_ms 250
  @default_max_buffer 200

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Admits an endpoint-inventory result directly to its bounded ingestion queue.

  Endpoint inventory acknowledgements are synchronous from the agent's point of
  view because ingestion may return reconciliation directives. They must not sit
  behind unrelated work in the singleton ResultsRouter mailbox while waiting to
  reach the dedicated queue.
  """
  @spec admit_endpoint_inventory(map(), GenServer.from()) ::
          :ok | {:ok, term()} | {:error, term()}
  def admit_endpoint_inventory(status, reply_to) when is_map(status) do
    process_and_publish(status, endpoint_inventory_reply_to: reply_to)
  end

  @doc false
  @spec process_retained_plugin(map()) :: :ok | {:error, term()}
  def process_retained_plugin(status) when is_map(status) do
    case handle_plugin_results(status) do
      # PluginResultIngestor returns the handler-domain error after it has
      # durably committed the corresponding failure marker. Retained delivery
      # may therefore acknowledge this terminal outcome, while persistence
      # failures below remain retryable.
      {:error, {:plugin_result_handlers_failed, _errors}} -> :ok
      result -> result
    end
  end

  @impl true
  def init(_state) do
    Logger.info("ResultsRouter started on node #{Node.self()}")
    state = %{buffer: [], buffer_size: 0, timer: nil}
    state = if batching_enabled?(), do: schedule_flush(state), else: state
    {:ok, state}
  end

  @impl true
  def handle_cast({:results_update, status}, state) do
    if batching_enabled?() do
      {:noreply, buffer_status(state, status)}
    else
      _result = process_and_publish(status)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:results_update, status}, _from, state) do
    # Sync path must reply per-item: process + publish immediately, not buffered.
    {:reply, process_and_publish(status), state}
  end

  @impl true
  def handle_call({:results_update_async_reply, status, reply_to}, _from, state) do
    {:reply, process_and_publish(status, endpoint_inventory_reply_to: reply_to), state}
  end

  @impl true
  def handle_info(:flush_results, state) do
    state = state |> flush_buffer() |> schedule_flush()
    {:noreply, state}
  end

  # ============================================================================
  # Async buffer + flush (cast path only)
  # ============================================================================

  defp buffer_status(state, status) do
    state = %{state | buffer: [status | state.buffer], buffer_size: state.buffer_size + 1}

    if state.buffer_size >= max_buffer() do
      state |> flush_buffer() |> reschedule_flush()
    else
      state
    end
  end

  defp flush_buffer(%{buffer_size: 0} = state), do: state

  defp flush_buffer(state) do
    statuses = Enum.reverse(state.buffer)

    # Per-status type-specific routing stays per item; only collect the ones whose
    # processing succeeded for the batched service-state publish, matching the
    # single-item contract (publish only on :ok / {:ok, _}).
    publishable =
      Enum.filter(statuses, fn status ->
        case process(status, []) do
          :ok -> true
          {:ok, _result} -> true
          {:error, reason} -> log_processing_error(reason)
        end
      end)

    publish_status_batch(publishable)

    %{state | buffer: [], buffer_size: 0}
  end

  defp log_processing_error(reason) do
    Logger.warning("Results processing failed: #{inspect(reason)}")
    false
  end

  defp publish_status_batch([]), do: :ok

  defp publish_status_batch(statuses) do
    statuses = Enum.reject(statuses, &plugin_result_status?/1)

    if statuses != [] do
      ServiceStateRegistry.bulk_upsert_from_statuses(statuses)
      ServiceStatusPubSub.broadcast_batch(statuses)
    end

    :ok
  rescue
    error ->
      Logger.warning("Service status batch publish failed", error: inspect(error))
  catch
    :exit, reason ->
      Logger.warning("Service status batch publish failed", reason: inspect(reason))
  end

  defp schedule_flush(state) do
    %{state | timer: Process.send_after(self(), :flush_results, flush_interval_ms())}
  end

  defp reschedule_flush(state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    schedule_flush(state)
  end

  defp batching_enabled? do
    Application.get_env(:serviceradar_core, :results_router_batching, true) == true
  end

  defp flush_interval_ms do
    case Application.get_env(:serviceradar_core, :results_router_flush_interval_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_flush_interval_ms
    end
  end

  defp max_buffer do
    case Application.get_env(:serviceradar_core, :results_router_max_buffer) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_buffer
    end
  end

  defp process_and_publish(status, opts \\ []) do
    # No per-message log here — hot path. Breadcrumbs come from the OTel span.
    case process(status, opts) do
      :ok ->
        publish_status_update(status)
        :ok

      {:ok, _result} = ok ->
        publish_status_update(status)
        ok

      {:error, reason} = error ->
        Logger.warning("Results processing failed: #{inspect(reason)}")
        error
    end
  end

  defp publish_status_update(%{source: source}) when source in ["plugin-result", :plugin_result],
    do: :ok

  defp publish_status_update(status) do
    ServiceStateRegistry.upsert_from_status(status)
    ServiceStatusPubSub.broadcast_update(status)
  rescue
    error ->
      Logger.warning("Service status publish failed", error: inspect(error))
  catch
    :exit, reason ->
      Logger.warning("Service status publish failed", reason: inspect(reason))
  end

  defp plugin_result_status?(%{source: source}) when source in ["plugin-result", :plugin_result],
    do: true

  defp plugin_result_status?(_status), do: false

  # Service types carried by the netprobe passive device census stream.
  #
  # Exposed via census_service_types/0 so the unit tier can assert that every
  # value here is one SourcePolicy.passive_census_source?/1 recognises. That
  # pairing is the whole guardrail: the router decides whether the payload
  # reaches the SyncIngestor, and the policy decides whether its MAC may anchor
  # a device. If the two lists drift, the stream ingests with the guardrail
  # silently inert -- no error, just randomized MACs minting devices.
  #
  # It cannot be checked in results_router_test.exs: that file uses
  # ServiceRadar.DataCase, which carries @moduletag :requires_app, and the unit
  # tier excludes :requires_app -- so those tests run only in the integration
  # shards.
  # Passive netprobe evidence: fingerprints, DPI and the local process listing.
  # In an attribute with an accessor for the same reason as the census and mDNS
  # lists below -- discovery_schema_registry_test.exs pins the DISCOVERY_V1
  # sources against the routes they replace, so the two cannot drift apart
  # silently while both paths are live.
  @passive_netprobe_service_types ["passive-netprobe", :passive_netprobe]

  @doc false
  def passive_netprobe_service_types, do: @passive_netprobe_service_types

  @census_service_types ["netprobe-census", :netprobe_census, "passive-census"]

  @doc false
  def census_service_types, do: @census_service_types

  # Service types carried by the netprobe mDNS identification stream.
  #
  # Paired with SourcePolicy.enrichment_only_source?/1 exactly as the census
  # list is paired with passive_census_source?/1, and asserted in the unit tier
  # for the same reason: if the two drift, mDNS ingests as an ordinary source
  # and starts MINTING devices from announcements instead of only describing
  # ones the census already found.
  @mdns_service_types ["netprobe-mdns", :netprobe_mdns, "passive-mdns"]

  @doc false
  def mdns_service_types, do: @mdns_service_types

  defp process(%{source: source, service_type: "sync"} = status, _opts)
       when source in ["results", :results] do
    handle_sync_results(status)
  end

  defp process(%{source: source, service_type: "sweep"} = status, _opts)
       when source in ["results", :results] do
    handle_sweep_results(status)
  end

  defp process(%{source: source, service_type: service_type} = status, _opts)
       when source in ["results", :results] and service_type in ["mapper", "mapper_discovery"] do
    handle_mapper_results(status)
  end

  defp process(%{source: source, service_type: service_type} = status, _opts)
       when source in ["results", :results] and service_type in @passive_netprobe_service_types do
    schedule_sync_ingestion(status)
  end

  # The netprobe passive L2 device census (ARP/NDP sightings).
  #
  # Same SyncIngestor path as passive-netprobe, deliberately: that pipeline is
  # where SourcePolicy.include_mac_identifier?/1 is consulted, and the census
  # MAC guardrail is inert anywhere else.
  #
  # Without this clause the stream falls through to the catch-all below, which
  # returns :ok and lets publish_status_update/1 run -- so the service reports
  # HEALTHY while its entire payload is discarded with no log line.
  defp process(%{source: source, service_type: service_type} = status, _opts)
       when source in ["results", :results] and service_type in @census_service_types do
    schedule_sync_ingestion(status)
  end

  # The netprobe mDNS identification stream.
  #
  # Same SyncIngestor path again, and the same reason it cannot be left to the
  # catch-all: that clause returns :ok and publishes a HEALTHY status while
  # discarding the entire payload without a log line.
  #
  # What makes this stream different is what happens once it arrives. Its
  # updates carry no IP and are not allowed to create a device -- see
  # SourcePolicy.enrichment_only_source?/1 and the gate in SyncIngestor. An
  # mDNS announcement describes a host; only the census establishes that the
  # host is there.
  defp process(%{source: source, service_type: service_type} = status, _opts)
       when source in ["results", :results] and service_type in @mdns_service_types do
    schedule_sync_ingestion(status)
  end

  defp process(%{source: source, service_type: "mapper_interfaces"} = status, _opts)
       when source in ["results", :results] do
    handle_mapper_interfaces(status)
  end

  defp process(%{source: source, service_type: "mapper_topology"} = status, _opts)
       when source in ["results", :results] do
    handle_mapper_topology(status)
  end

  defp process(%{source: source, service_type: "bumblebee"} = status, _opts)
       when source in ["results", :results] do
    handle_bumblebee_results(status)
  end

  defp process(%{source: source, service_type: "endpoint_inventory"} = status, opts)
       when source in ["results", :results] do
    handle_endpoint_inventory_results(status, opts)
  end

  defp process(%{source: source} = status, _opts)
       when source in ["sysmon-metrics", :sysmon_metrics] do
    handle_sysmon_metrics(status)
  end

  defp process(%{source: source} = status, _opts)
       when source in ["snmp-metrics", :snmp_metrics] do
    handle_snmp_metrics(status)
  end

  defp process(%{source: source} = status, _opts)
       when source in ["icmp-metrics", :icmp_metrics] do
    handle_icmp_results(status)
  end

  defp process(%{source: source} = status, _opts)
       when source in ["rperf-metrics", :rperf_metrics] do
    handle_rperf_metrics(status)
  end

  defp process(%{source: source} = status, _opts) when source in ["mtr-metrics", :mtr_metrics] do
    handle_mtr_metrics(status)
  end

  defp process(%{source: source} = status, _opts)
       when source in ["sweep-metrics", :sweep_metrics] do
    handle_sweep_metrics(status)
  end

  defp process(%{source: source} = status, _opts)
       when source in ["plugin-result", :plugin_result] do
    handle_plugin_results(status)
  end

  defp process(%{source: source, service_type: "mtr"} = status, _opts)
       when source in ["results", :results] do
    handle_mtr_results(status)
  end

  defp process(_status, _opts), do: :ok

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

  defp handle_bumblebee_results(status) do
    with {:ok, payload} <- decode_payload(status[:message]) do
      payload
      |> Map.put_new("agent_id", status[:agent_id])
      |> BumblebeeIngestor.ingest_scan()
    end
  end

  defp handle_endpoint_inventory_results(status, opts) do
    with {:ok, payload} <- decode_payload(status[:message]) do
      payload = Map.put_new(payload, "agent_id", status[:agent_id])

      if Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_async, true) do
        case Keyword.fetch(opts, :endpoint_inventory_reply_to) do
          {:ok, reply_to} -> EndpointInventoryIngestorQueue.enqueue_and_reply(payload, reply_to)
          :error -> EndpointInventoryIngestorQueue.enqueue(payload)
        end
      else
        EndpointInventoryIngestor.ingest_report(payload)
      end
    end
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
      banner_grab_summary = parse_banner_grab_summary(payload)

      opts =
        Enum.reject(
          [
            sweep_group_id: sweep_group_id,
            agent_id: status[:agent_id],
            authenticated_agent_id: status[:agent_id],
            authenticated_partition_id: status[:authenticated_partition],
            actor: actor,
            expected_total_hosts: expected_total_hosts,
            scanner_metrics: scanner_metrics,
            banner_grab_summary: banner_grab_summary,
            request_id: status[:request_id],
            chunk_index: status[:chunk_index],
            total_chunks: status[:total_chunks],
            is_final: status[:is_final]
          ],
          fn {_key, value} -> is_nil(value) or value == "" end
        )

      case sweep_ingestor().ingest_results(results, execution_id, opts) do
        :ok -> :ok
        {:ok, _stats} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp handle_sysmon_metrics(status) do
    reject_gateway_metric_status(status)
  end

  defp handle_snmp_metrics(status) do
    reject_gateway_metric_status(status)
  end

  defp handle_sweep_metrics(status) do
    reject_gateway_metric_status(status)
  end

  defp handle_plugin_results(status) do
    case decode_payload(status[:message]) do
      {:ok, payload} ->
        with :ok <- reject_legacy_plugin_metrics(payload) do
          plugin_ingestor().ingest(payload, status)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_legacy_plugin_metrics(payload) when is_map(payload) do
    if Map.has_key?(payload, "metrics") or Map.has_key?(payload, :metrics) do
      {:error, :plugin_result_metrics_unsupported}
    else
      :ok
    end
  end

  defp reject_legacy_plugin_metrics(payload) when is_list(payload) do
    if Enum.any?(payload, &legacy_plugin_metrics?/1) do
      {:error, :plugin_result_metrics_unsupported}
    else
      :ok
    end
  end

  defp reject_legacy_plugin_metrics(_payload), do: :ok

  defp legacy_plugin_metrics?(payload) when is_map(payload) do
    Map.has_key?(payload, "metrics") or Map.has_key?(payload, :metrics)
  end

  defp legacy_plugin_metrics?(_payload), do: false

  defp handle_icmp_results(status) do
    reject_gateway_metric_status(status)
  end

  defp handle_rperf_metrics(status) do
    reject_gateway_metric_status(status)
  end

  defp handle_mtr_metrics(status) do
    reject_gateway_metric_status(status)
  end

  defp handle_mtr_results(status) do
    case decode_payload(status[:message]) do
      {:ok, payload} -> mtr_ingestor().ingest(payload, status)
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
      present_id?(payload_id) ->
        payload_id

      missing_payload_id?(payload_id, deterministic_id) ->
        Logger.warning("Sweep results missing execution_id; using deterministic execution id")
        deterministic_id

      present_id?(deterministic_id) ->
        deterministic_id

      true ->
        Ash.UUID.generate()
    end
  end

  defp missing_payload_id?(payload_id, deterministic_id) do
    not present_id?(payload_id) and present_id?(deterministic_id)
  end

  defp present_id?(value) when is_binary(value), do: value != ""
  defp present_id?(_value), do: false

  defp deterministic_execution_id(sweep_group_id, last_sweep_time)
       when is_binary(sweep_group_id) and sweep_group_id != "" and is_binary(last_sweep_time) and
              last_sweep_time != "" do
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

    if is_map(value), do: value
  end

  defp parse_scanner_metrics(_payload), do: nil

  defp parse_banner_grab_summary(payload) when is_map(payload) do
    value = payload["banner_grab"] || payload["bannerGrab"]

    if is_map(value), do: value
  end

  defp parse_banner_grab_summary(_payload), do: nil

  defp build_sweep_result(host, last_sweep_time, network) when is_map(host) do
    case host_ip(host) do
      host_ip when is_binary(host_ip) and host_ip != "" ->
        icmp_status = icmp_status(host)

        canonical_port_results =
          host
          |> port_results()
          |> build_port_scan_results()
          |> merge_tcp_open_ports(tcp_open_ports(host))

        base = %{
          "host_ip" => host_ip,
          "hostname" => host["hostname"],
          "available" => host_available(host, icmp_status, canonical_port_results),
          "icmp_response_time_ns" => icmp_response_time_ns(host, icmp_status),
          "icmp_packet_loss" => icmp_packet_loss(icmp_status),
          "port_results" => canonical_port_results,
          "error" => host["error"],
          "last_sweep_time" => last_sweep_time
        }

        base
        |> maybe_put_icmp_available(host, icmp_status)
        |> maybe_put_network(network)

      _ ->
        nil
    end
  end

  defp build_sweep_result(_host, _last_sweep_time, _network), do: nil

  defp host_ip(host) do
    value = host["host"]

    if is_binary(value) and value != "" do
      value
    end
  end

  defp port_results(host) when is_map(host) do
    host["port_results"] || host["port_scan_results"] || host["portScanResults"] || []
  end

  defp tcp_open_ports(host) when is_map(host) do
    host["tcp_ports_open"] || host["tcpPortsOpen"] || []
  end

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
      host["icmp_available"] || host["icmpAvailable"] || false
    end
  end

  defp maybe_put_icmp_available(result, _host, icmp_status) when is_map(icmp_status) do
    Map.put(result, "icmp_available", icmp_available(%{}, icmp_status))
  end

  defp maybe_put_icmp_available(result, host, _icmp_status) do
    if Map.has_key?(host, "icmp_available") or Map.has_key?(host, "icmpAvailable") do
      Map.put(result, "icmp_available", icmp_available(host, nil))
    else
      result
    end
  end

  defp host_available(host, icmp_status, port_results) do
    host["available"] == true ||
      icmp_available(host, icmp_status) ||
      Enum.any?(port_results, &(&1["available"] == true))
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

  defp merge_tcp_open_ports(port_results, open_ports) do
    open_ports =
      open_ports
      |> List.wrap()
      |> Enum.map(&parse_integer/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&valid_port?/1)

    if open_ports == [] do
      port_results
    else
      port_results
      |> Map.new(fn result -> {result["port"], result} end)
      |> then(fn by_port ->
        Enum.reduce(open_ports, by_port, fn port, acc ->
          result =
            acc
            |> Map.get(port, %{"port" => port, "response_time_ns" => 0})
            |> Map.put("available", true)

          Map.put(acc, port, result)
        end)
      end)
      |> Map.values()
      |> Enum.sort_by(& &1["port"])
    end
  end

  defp valid_port?(port), do: port >= 1 and port <= 65_535

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

  defp reject_gateway_metric_status(status) do
    {:error, {:gateway_metric_status_not_core_routable, status[:source]}}
  end

  defp sweep_ingestor do
    Application.get_env(:serviceradar_core, :sweep_ingestor, SweepResultsIngestor)
  end

  defp plugin_ingestor do
    Application.get_env(:serviceradar_core, :plugin_result_ingestor, PluginResultIngestor)
  end

  defp mtr_ingestor do
    Application.get_env(:serviceradar_core, :mtr_metrics_ingestor, MtrMetricsIngestor)
  end
end
