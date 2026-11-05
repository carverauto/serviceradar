defmodule ServiceRadarAgentGateway.StatusProcessor do
  @moduledoc """
  Forwards an agent's ephemeral status summaries to the core status handler.

  `PushStatus` and `StreamStatus` carry only latest-wins status summaries: service health
  heartbeats (source `status`, including the `agent` capability status core reads add-on state
  from) and plugin-engine counters (source `plugin-telemetry`). Durable agent data reaches the
  platform only as edge records (`EdgeRecordIngestServer`); `RetiredStatusSources` refuses it on
  this path before anything here runs.

  A summary is forwarded best-effort: `StatusBuffer` owns it once the RPC has answered, and a
  newer summary replaces whatever a lost one said.
  """

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Ingestion.Admission
  alias ServiceRadarAgentGateway.ClusterProcessLocator
  alias ServiceRadarAgentGateway.RuntimeMetrics

  require Logger

  # Every core call has to finish inside the delivery the buffer is waiting on.
  @core_call_timeout_ms 20_000
  @admission_probe_timeout_ms 250

  @doc """
  Forward one status summary to core and track the agent that sent it.

  `status` is the map `AgentGatewayServer` builds: `:service_name`, `:service_type` and
  `:agent_id` are required; `:message`, `:available`, `:response_time`, `:partition`,
  `:gateway_id`, `:source` and timestamps ride along.

  Option `:from_buffer` only labels the forward metrics.
  """
  @spec process(map(), keyword()) :: :ok | {:error, term()}
  def process(status, opts \\ []) do
    with :ok <- validate_status(status) do
      status = normalize_status(status)
      started_at = System.monotonic_time()
      from_buffer = Keyword.get(opts, :from_buffer, false)

      case forward_to_core(status) do
        :ok ->
          emit_forward_metrics(:ok, status, from_buffer, started_at)
          track_agent(status)
          :ok

        {:error, reason} ->
          emit_forward_metrics(:failed, status, from_buffer, started_at)
          {:error, reason}
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

  defp normalize_status(status) do
    status
    |> Map.put_new(:timestamp, System.system_time(:nanosecond))
    |> Map.put_new(:partition, "default")
    |> Map.update(:message, nil, &normalize_message/1)
  end

  defp normalize_message(nil), do: nil
  defp normalize_message(msg) when is_binary(msg), do: msg
  defp normalize_message(msg), do: inspect(msg)

  defp forward_to_core(status) do
    handler = ServiceRadar.StatusHandler

    Logger.debug(
      "Forwarding status to core: partition=#{status[:partition]} " <>
        "agent=#{status[:agent_id]} service=#{status[:service_name]}"
    )

    case forward_local(status, handler) do
      {:error, :not_available} -> forward_distributed(status, handler)
      result -> result
    end
  end

  defp forward_local(status, handler) do
    case Process.whereis(handler) do
      nil ->
        {:error, :not_available}

      pid when is_pid(pid) ->
        try do
          forward_handler(pid, status)
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

  defp forward_distributed(status, handler) do
    case find_handler_node(handler) do
      {:ok, node} ->
        try do
          result = forward_handler({handler, node}, status)
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

  # Metadata first: a rejected status never enters a core payload mailbox.
  # Never fall back on a probe timeout: that is precisely when transferring an
  # unreserved payload could grow a saturated core's mailbox. Unreserved
  # forwarding is an explicit rollout setting, not an overload escape hatch.
  defp forward_handler(target, status) do
    deadline = System.monotonic_time(:millisecond) + core_call_timeout_ms()

    if Application.get_env(:serviceradar_agent_gateway, :reserved_core_admission, true) do
      submit_reserved(target, status, deadline)
    else
      GenServer.cast(target, {:status_update, status})
    end
  end

  defp submit_reserved(target, status, deadline) do
    remaining = min(remaining_ms(deadline), Admission.budget_ms())
    descriptor = Lane.descriptor(status, remaining)

    with :ok <- ensure_reserved_admission(target, deadline),
         {:ok, {lane, id}} <-
           GenServer.call(target, {:reserve_status, descriptor}, min(remaining_ms(deadline), 1_100)) do
      GenServer.call(lane, {:submit, id, status, :best_effort}, remaining_ms(deadline))
    end
  end

  defp ensure_reserved_admission(target, deadline) do
    # Probe the deployed module, not an older GenServer's unknown callback.
    # An unsupported core pair fails closed without crashing its dispatcher.
    target_node = target_node(target)
    module = admission_protocol_module()

    case ClusterProcessLocator.cached_admission_protocol(target_node, module) do
      {:ok, :reserved_v1} ->
        :ok

      {:miss, generation} ->
        probe_reserved_admission(target_node, module, generation, deadline)
    end
  end

  defp probe_reserved_admission(target_node, module, generation, deadline) do
    timeout_ms = min(remaining_ms(deadline), @admission_probe_timeout_ms)

    try do
      case :erpc.call(target_node, module, :admission_protocol, [], timeout_ms) do
        :reserved_v1 ->
          ClusterProcessLocator.cache_admission_protocol(target_node, module, :reserved_v1, generation)
          :ok

        _other ->
          {:error, :core_admission_protocol_unavailable}
      end
    catch
      :error, {:erpc, :timeout} ->
        {:error, :core_admission_probe_timeout}

      :error, {:exception, :undef, _stacktrace} ->
        {:error, :core_admission_protocol_unavailable}

      _kind, _reason ->
        {:error, :core_admission_protocol_unavailable}
    end
  end

  defp target_node(pid) when is_pid(pid), do: node(pid)
  defp target_node({_name, target_node}), do: target_node
  defp target_node(_name), do: node()

  defp admission_protocol_module do
    Application.get_env(
      :serviceradar_agent_gateway,
      :admission_protocol_module,
      ServiceRadar.StatusHandler
    )
  end

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp core_call_timeout_ms do
    case Application.get_env(:serviceradar_agent_gateway, :core_call_timeout_ms, @core_call_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @core_call_timeout_ms
    end
  end

  # Find a connected node that runs the handler. The locator answers from its
  # cache and never waits on a node that does not respond when another one does.
  defp find_handler_node(handler) do
    case ClusterProcessLocator.nodes(handler) do
      [node | _] -> {:ok, node}
      [] -> {:error, :not_found}
    end
  end

  defp emit_forward_metrics(result, status, from_buffer, started_at) do
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

    RuntimeMetrics.report_core_call(duration_ms, result, status)
  end
end
