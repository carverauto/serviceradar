defmodule ServiceRadarAgentGateway.StatusProcessor do
  @moduledoc """
  Processes service status updates received from agents.

  This module is the integration point between the agent gateway, local
  JetStream ingress, and the ServiceRadar core. It handles:

  1. Validation of incoming status data
  2. Normalization of status formats
  3. Publishing gateway-owned ingress subjects or forwarding to core handlers
  4. Recording of telemetry/metrics

  ## Integration with Core

  Status updates that are not gateway-owned ingress messages are forwarded to
  the distributed core cluster via:
  - Direct GenServer calls for local processing
  - Distributed routing for partition-aware processing
  """

  alias ServiceRadarAgentGateway.IcmpMetricsPublisher
  alias ServiceRadarAgentGateway.K8sPublicEndpointsPublisher
  alias ServiceRadarAgentGateway.MtrMetricsPublisher
  alias ServiceRadarAgentGateway.OtlpRelayPublisher
  alias ServiceRadarAgentGateway.PluginMetricsPublisher
  alias ServiceRadarAgentGateway.RperfMetricsPublisher
  alias ServiceRadarAgentGateway.SnmpMetricsPublisher
  alias ServiceRadarAgentGateway.StatusBuffer
  alias ServiceRadarAgentGateway.SweepMetricsPublisher
  alias ServiceRadarAgentGateway.SysmonMetricsPublisher

  require Logger

  @core_call_timeout_ms 30_000
  @flow_attribution_core_call_timeout_ms 25_000
  @plugin_result_retained_delivery_capability_v1 "plugin-result-retained:v1"

  @doc """
  Process a service status update.

  Takes a status map and either publishes it at the gateway ingress boundary or
  forwards it to the appropriate handler in the core cluster.

  ## Parameters

    - `status`: A map containing:
      - `:service_name` - Name of the service
      - `:available` - Boolean availability status
      - `:message` - Status message (binary)
      - `:service_type` - Type of service (e.g., "sweep", "process")
      - `:response_time` - Response time in nanoseconds
      - `:agent_id` - ID of the reporting agent
      - `:gateway_id` - ID of the gateway
      - `:partition` - Partition identifier
      - `:source` - Source type ("status" or "results")
      - `:kv_store_id` - KV store identifier
      - `:timestamp` - Unix timestamp in nanoseconds

  ## Returns

    - `:ok` on success
    - `{:ok, result}` when synchronous processing returns an acknowledgement result
    - `{:error, reason}` on failure
  """
  @spec process(map(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def process(status, opts \\ []) do
    with :ok <- validate_status(status) do
      status = normalize_status(status)

      case maybe_publish_otlp_relay(status) do
        :disabled ->
          {:error, :otlp_relay_publisher_disabled}

        :not_otlp_relay ->
          route_non_otlp_relay_status(status, opts)

        :ok ->
          track_agent(status)
          :ok

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Extracted from process/2 to keep each publisher's dispatch one `case` deep. The chain is
  # ordered, not parallel: a status owned by a specific publisher must not also be forwarded
  # down the generic gateway-metrics path, so each publisher gets the chance to claim the
  # status and only `:not_*` falls through to the next one.
  defp route_non_otlp_relay_status(status, opts) do
    case maybe_publish_k8s_public_endpoints(status) do
      :not_k8s_public_endpoints ->
        publish_then_forward(status, opts)

      :disabled ->
        {:error, :k8s_public_endpoints_publisher_disabled}

      :ok ->
        track_agent(status)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp publish_then_forward(status, opts) do
    case publish_gateway_metrics(status) do
      :ok ->
        if gateway_metric_status?(status) do
          track_agent(status)
          :ok
        else
          forward_then_track(status, opts)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp forward_then_track(status, opts) do
    case forward(status, opts) do
      :ok ->
        track_agent(status)
        :ok

      {:ok, _result} = ok ->
        track_agent(status)
        ok

      {:error, _reason} = error ->
        error
    end
  end

  defp publish_gateway_metrics(status) do
    Enum.reduce_while(
      [
        {:sysmon, publish_sysmon_metrics(status)},
        {:snmp, publish_snmp_metrics(status)},
        {:icmp, publish_icmp_metrics(status)},
        {:package_telemetry, publish_plugin_metrics(status)},
        {:rperf, publish_rperf_metrics(status)},
        {:mtr, publish_mtr_metrics(status)},
        {:sweep, publish_sweep_metrics(status)}
      ],
      :ok,
      fn
        {_source, result}, :ok when result in [:ok, nil] ->
          {:cont, :ok}

        {source, :disabled}, :ok when source in [:sysmon, :snmp, :icmp, :rperf, :mtr, :sweep] ->
          {:halt, {:error, {:metric_publish_disabled, source}}}

        {_source, :disabled}, :ok ->
          {:cont, :ok}

        {source, {:error, reason}}, :ok ->
          {:halt, {:error, {:metric_publish_failed, source, reason}}}
      end
    )
  end

  defp maybe_publish_otlp_relay(%{source: source} = status) when source in ["otlp-relay", :otlp_relay],
    do: otlp_relay_publisher().publish_relay(status)

  defp maybe_publish_otlp_relay(_status), do: :not_otlp_relay

  defp otlp_relay_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :otlp_relay_publisher_module,
      OtlpRelayPublisher
    )
  end

  defp maybe_publish_k8s_public_endpoints(status) do
    k8s_public_endpoints_publisher().publish(status)
  end

  defp k8s_public_endpoints_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :k8s_public_endpoints_publisher_module,
      K8sPublicEndpointsPublisher
    )
  end

  @spec forward(map(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def forward(status, opts \\ []) do
    buffer_on_failure = Keyword.get(opts, :buffer_on_failure, true)
    from_buffer = Keyword.get(opts, :from_buffer, false)
    started_at = System.monotonic_time()

    case forward_to_core(status) do
      :ok ->
        emit_forward_metrics(:ok, status, from_buffer, started_at)
        :ok

      {:ok, _result} = ok ->
        emit_forward_metrics(:ok, status, from_buffer, started_at)
        ok

      {:error, reason} ->
        if buffer_on_failure and should_buffer?(status) do
          enqueue_buffered_status(status)
          emit_forward_metrics(:buffered, status, from_buffer, started_at)
          :ok
        else
          emit_forward_metrics(:failed, status, from_buffer, started_at)
          {:error, reason}
        end
    end
  end

  defp enqueue_buffered_status(status) do
    case Process.whereis(StatusBuffer) do
      nil ->
        Logger.warning("Status buffer unavailable; dropping status")
        StatusBuffer.record_drop(status, :unavailable)

      _pid ->
        case StatusBuffer.enqueue(status) do
          :ok ->
            :ok

          {:error, :unavailable} ->
            Logger.warning("Status buffer unavailable; dropping status")
            StatusBuffer.record_drop(status, :unavailable)
        end
    end
  end

  # Track the agent that sent this status update
  defp track_agent(status) do
    agent_id = status[:agent_id]

    metadata = %{
      service_count: 1,
      partition: status[:partition],
      source_ip: status[:source_ip],
      gateway_id: status[:gateway_id]
    }

    ServiceRadar.AgentTracker.track_agent(agent_id, metadata)
  rescue
    # AgentTracker may not be available (e.g., during tests)
    _ -> :ok
  end

  # Validate required fields in the status
  defp validate_status(status) do
    required_fields = [:service_name, :service_type, :agent_id]

    missing =
      Enum.filter(required_fields, fn field ->
        value = Map.get(status, field)
        is_nil(value) or value == ""
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_fields, missing}}
    end
  end

  # Normalize status data for consistent processing
  defp normalize_status(status) do
    status
    |> Map.put_new(:timestamp, System.system_time(:nanosecond))
    |> Map.put_new(:partition, "default")
    |> Map.update(:message, nil, &normalize_message/1)
  end

  # Ensure message is properly formatted
  defp normalize_message(nil), do: nil
  defp normalize_message(msg) when is_binary(msg), do: msg
  defp normalize_message(msg), do: inspect(msg)

  # Forward the status to the core cluster
  defp forward_to_core(status) do
    partition = status[:partition]
    agent_id = status[:agent_id]
    service_name = status[:service_name]
    handler = ServiceRadar.StatusHandler

    Logger.debug(
      "Forwarding status to core: partition=#{partition} " <>
        "agent=#{agent_id} service=#{service_name}"
    )

    # Try to forward to the core cluster
    # First check if we have a local core process, then try distributed
    case forward_local(status, handler) do
      :ok ->
        :ok

      {:ok, _result} = ok ->
        ok

      {:error, :not_available} ->
        forward_distributed(status, handler)

      # Synchronous handlers can reply with a real failure (e.g. the
      # otlp-relay NATS publish failed); propagate it instead of crashing.
      {:error, _reason} = error ->
        error
    end
  end

  # Forward to local core process (same node)
  defp forward_local(status, handler) do
    # Check if core is available locally
    message = handler_message(status)

    case Process.whereis(handler) do
      nil ->
        {:error, :not_available}

      pid when is_pid(pid) ->
        try do
          if ack_result_status?(status) do
            GenServer.call(pid, message, core_call_timeout_ms(status))
          else
            GenServer.cast(pid, message)
            :ok
          end
        catch
          :exit, {:timeout, _call} ->
            {:error, :forward_timeout}

          :exit, {:noproc, _call} ->
            {:error, :not_available}

          :exit, reason ->
            Logger.warning("Failed to forward status to local core: #{inspect(reason)}")
            {:error, :forward_failed}
        end
    end
  end

  # Forward to distributed core process via RPC
  defp forward_distributed(status, handler) do
    message = handler_message(status)

    case find_handler_node(handler) do
      {:ok, node} ->
        try do
          # Cast to the core handler on the remote node
          result =
            if ack_result_status?(status) do
              GenServer.call({handler, node}, message, core_call_timeout_ms(status))
            else
              GenServer.cast({handler, node}, message)
              :ok
            end

          Logger.debug("Forwarded status to #{inspect(handler)} on #{node}")

          result
        catch
          :exit, reason ->
            Logger.warning("Failed to forward status to core on #{node}: #{inspect(reason)}")
            {:error, :forward_failed}
        end

      {:error, :not_found} ->
        Logger.debug("No handler found on any node")
        {:error, :not_available}
    end
  end

  defp handler_message(status), do: {:status_update, status}

  defp ack_result_status?(%{source: source, service_type: service_type})
       when source in ["results", :results] and service_type in ["endpoint_inventory", :endpoint_inventory], do: true

  defp ack_result_status?(%{source: source}) when source in ["flow-attribution", :flow_attribution], do: true

  defp ack_result_status?(%{source: source} = status) when source in ["plugin-result", :plugin_result],
    do: retained_plugin_result_delivery?(status)

  defp ack_result_status?(_status), do: false

  defp core_call_timeout_ms(%{source: source}) when source in ["flow-attribution", :flow_attribution] do
    Application.get_env(
      :serviceradar_agent_gateway,
      :flow_attribution_core_call_timeout_ms,
      @flow_attribution_core_call_timeout_ms
    )
  end

  defp core_call_timeout_ms(_status), do: @core_call_timeout_ms

  # Find a node that has the handler running
  defp find_handler_node(handler) do
    nodes = Enum.uniq([Node.self() | Node.list()])

    # First, try to find nodes with the handler
    handler_nodes =
      Enum.filter(nodes, fn node ->
        case :rpc.call(node, Process, :whereis, [handler], 5_000) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end)

    case handler_nodes do
      [node | _] -> {:ok, node}
      [] -> {:error, :not_found}
    end
  end

  # The agent retains flow attribution and capability-qualified plugin results
  # until the gateway truthfully acknowledges durable downstream acceptance.
  # Putting either source in this volatile queue would transfer ownership too
  # early and turn a core failure into data loss on gateway restart/overflow.
  defp should_buffer?(%{source: source}) when source in ["flow-attribution", :flow_attribution], do: false

  defp should_buffer?(%{source: source} = status) when source in ["plugin-result", :plugin_result],
    do: not retained_plugin_result_delivery?(status)

  defp should_buffer?(status), do: results_router_source?(status)

  defp retained_plugin_result_delivery?(status) do
    @plugin_result_retained_delivery_capability_v1 in List.wrap(Map.get(status, :delivery_capabilities, []))
  end

  defp results_router_source?(status) do
    source = status[:source]

    source in [
      "results",
      :results,
      "sysmon-metrics",
      :sysmon_metrics,
      "snmp-metrics",
      :snmp_metrics,
      "icmp-metrics",
      :icmp_metrics,
      "rperf-metrics",
      :rperf_metrics,
      "mtr-metrics",
      :mtr_metrics,
      "sweep-metrics",
      :sweep_metrics,
      "workload-identity",
      :workload_identity
    ] or package_telemetry_source?(source)
  end

  defp gateway_metric_status?(status) do
    sysmon_metrics_source?(status) or snmp_metrics_source?(status) or icmp_metrics_source?(status) or
      rperf_metrics_source?(status) or mtr_metrics_source?(status) or sweep_metrics_source?(status)
  end

  defp publish_icmp_metrics(status) do
    if icmp_metrics_source?(status) do
      case icmp_metrics_publisher().publish_icmp(status) do
        :ok ->
          :ok

        :disabled ->
          :disabled

        {:error, reason} ->
          Logger.warning("ICMP metrics publish failed",
            reason: inspect(reason),
            agent_id: status[:agent_id],
            gateway_id: status[:gateway_id],
            partition: status[:partition]
          )

          {:error, reason}
      end
    end
  end

  defp icmp_metrics_source?(%{source: source}), do: source in ["icmp-metrics", :icmp_metrics]
  defp icmp_metrics_source?(_status), do: false

  defp icmp_metrics_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :icmp_metrics_publisher_module,
      IcmpMetricsPublisher
    )
  end

  defp publish_sysmon_metrics(status) do
    if sysmon_metrics_source?(status) do
      case sysmon_metrics_publisher().publish_sysmon(status) do
        :ok ->
          :ok

        :disabled ->
          :disabled

        {:error, reason} ->
          Logger.warning("Sysmon metrics publish failed",
            reason: inspect(reason),
            agent_id: status[:agent_id],
            gateway_id: status[:gateway_id],
            partition: status[:partition]
          )

          {:error, reason}
      end
    end
  end

  defp sysmon_metrics_source?(%{source: source}), do: source in ["sysmon-metrics", :sysmon_metrics]

  defp sysmon_metrics_source?(_status), do: false

  defp sysmon_metrics_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :sysmon_metrics_publisher_module,
      SysmonMetricsPublisher
    )
  end

  defp publish_snmp_metrics(status) do
    if snmp_metrics_source?(status) do
      case snmp_metrics_publisher().publish_snmp(status) do
        :ok ->
          :ok

        :disabled ->
          :disabled

        {:error, reason} ->
          Logger.warning("SNMP metrics publish failed",
            reason: inspect(reason),
            agent_id: status[:agent_id],
            gateway_id: status[:gateway_id],
            partition: status[:partition]
          )

          {:error, reason}
      end
    end
  end

  defp snmp_metrics_source?(%{source: source}), do: source in ["snmp-metrics", :snmp_metrics]
  defp snmp_metrics_source?(_status), do: false

  defp snmp_metrics_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :snmp_metrics_publisher_module,
      SnmpMetricsPublisher
    )
  end

  defp publish_plugin_metrics(status) do
    if plugin_result_source?(status) do
      case plugin_metrics_publisher().publish_plugin_metrics(status) do
        :ok ->
          :ok

        :disabled ->
          :disabled

        {:error, reason} ->
          Logger.warning("Plugin metrics publish failed",
            reason: inspect(reason),
            agent_id: status[:agent_id],
            gateway_id: status[:gateway_id],
            partition: status[:partition],
            service_name: status[:service_name]
          )

          {:error, reason}
      end
    end
  end

  defp plugin_result_source?(%{source: source}), do: package_telemetry_source?(source)

  defp plugin_result_source?(_status), do: false

  defp plugin_metrics_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :plugin_metrics_publisher_module,
      PluginMetricsPublisher
    )
  end

  defp publish_rperf_metrics(status) do
    if rperf_metrics_source?(status) do
      case rperf_metrics_publisher().publish_rperf(status) do
        :ok ->
          :ok

        :disabled ->
          :disabled

        {:error, reason} ->
          Logger.warning("RPerf metrics publish failed",
            reason: inspect(reason),
            agent_id: status[:agent_id],
            gateway_id: status[:gateway_id],
            partition: status[:partition]
          )

          {:error, reason}
      end
    end
  end

  defp rperf_metrics_source?(%{source: source}), do: source in ["rperf-metrics", :rperf_metrics]
  defp rperf_metrics_source?(_status), do: false

  defp rperf_metrics_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :rperf_metrics_publisher_module,
      RperfMetricsPublisher
    )
  end

  defp publish_mtr_metrics(status) do
    if mtr_metrics_source?(status) do
      case mtr_metrics_publisher().publish_mtr(status) do
        :ok ->
          :ok

        :disabled ->
          :disabled

        {:error, reason} ->
          Logger.warning("MTR metrics publish failed",
            reason: inspect(reason),
            agent_id: status[:agent_id],
            gateway_id: status[:gateway_id],
            partition: status[:partition]
          )

          {:error, reason}
      end
    end
  end

  defp mtr_metrics_source?(%{source: source}), do: source in ["mtr-metrics", :mtr_metrics]
  defp mtr_metrics_source?(_status), do: false

  defp mtr_metrics_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :mtr_metrics_publisher_module,
      MtrMetricsPublisher
    )
  end

  defp publish_sweep_metrics(status) do
    if sweep_metrics_source?(status) do
      case sweep_metrics_publisher().publish_sweep(status) do
        :ok ->
          :ok

        :disabled ->
          :disabled

        {:error, reason} ->
          Logger.warning("Sweep metrics publish failed",
            reason: inspect(reason),
            agent_id: status[:agent_id],
            gateway_id: status[:gateway_id],
            partition: status[:partition]
          )

          {:error, reason}
      end
    end
  end

  defp sweep_metrics_source?(%{source: source}), do: source in ["sweep-metrics", :sweep_metrics]
  defp sweep_metrics_source?(_status), do: false

  defp sweep_metrics_publisher do
    Application.get_env(
      :serviceradar_agent_gateway,
      :sweep_metrics_publisher_module,
      SweepMetricsPublisher
    )
  end

  defp package_telemetry_source?(source) when is_binary(source), do: String.starts_with?(source, ["addon:", "plugin:"])

  defp package_telemetry_source?(_source), do: false

  defp emit_forward_metrics(result, status, from_buffer, started_at) do
    if should_buffer?(status) do
      duration_ms =
        System.monotonic_time()
        |> Kernel.-(started_at)
        |> System.convert_time_unit(:native, :millisecond)

      :telemetry.execute(
        [:serviceradar, :agent_gateway, :results, :forward],
        %{count: 1, duration_ms: duration_ms},
        %{
          result: result,
          from_buffer: from_buffer,
          service_type: status[:service_type],
          service_name: status[:service_name],
          agent_id: status[:agent_id],
          gateway_id: status[:gateway_id],
          partition: status[:partition]
        }
      )
    end
  end
end
