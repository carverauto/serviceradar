defmodule ServiceRadar.Edge.AgentCommandBus do
  @moduledoc """
  Dispatches on-demand agent commands over the control stream.
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandCleanupWorker
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.ProcessRegistry

  @default_ttl_seconds 60
  @send_timeout 5_000

  def dispatch(agent_id, command_type, payload, opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    created_at = System.system_time(:second)
    required_partition = Keyword.get(opts, :required_partition)
    required_capability = Keyword.get(opts, :required_capability)
    partition_id = resolve_partition(opts, required_partition)
    context = opts |> Keyword.get(:context, %{}) |> normalize_context()
    payload_json = encode_payload(payload)
    payload_map = normalize_payload(payload)

    command_attrs = %{
      command_type: command_type,
      agent_id: agent_id,
      partition_id: partition_id,
      payload: payload_map,
      context: context,
      ttl_seconds: ttl_seconds,
      requested_by: requested_by_id(Keyword.get(opts, :actor))
    }

    ash_opts = [actor: SystemActor.system(:agent_command_bus)]

    case AgentCommand.create_command(command_attrs, ash_opts) do
      {:ok, command} ->
        _ = AgentCommandCleanupWorker.ensure_scheduled()

        dispatch_created_command(command, %{
          agent_id: agent_id,
          command_type: command_type,
          payload_json: payload_json,
          ttl_seconds: ttl_seconds,
          created_at: created_at,
          required_partition: required_partition,
          required_capability: required_capability,
          context: context,
          ash_opts: ash_opts
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_created_command(command, ctx) do
    command_request =
      build_command_request(
        command.id,
        ctx.command_type,
        ctx.payload_json,
        ctx.ttl_seconds,
        ctx.created_at
      )

    case lookup_control_session(ctx.agent_id) do
      {:ok, pid, metadata} ->
        dispatch_to_session(
          command,
          pid,
          metadata,
          command_request,
          ctx
        )

      {:error, {:agent_offline, _} = reason} ->
        _ = mark_offline(command, reason, ctx.ash_opts)
        {:error, reason}

      {:error, reason} ->
        _ = mark_failed(command, reason, ctx.ash_opts)
        {:error, reason}
    end
  end

  defp dispatch_to_session(command, pid, metadata, command_request, ctx) do
    case ensure_assignment(
           ctx.agent_id,
           metadata,
           ctx.required_partition,
           ctx.required_capability
         ) do
      :ok ->
        send_command(command, pid, metadata, command_request, ctx)

      {:error, reason} ->
        _ = mark_failed(command, reason, ctx.ash_opts)
        {:error, reason}
    end
  end

  defp send_command(command, pid, metadata, command_request, ctx) do
    actual_partition = partition_from_metadata(metadata)

    command_context =
      build_command_context(ctx.context, command, actual_partition, ctx.created_at)

    case GenServer.call(pid, {:send_command, command_request, command_context}, @send_timeout) do
      {:ok, _} ->
        _ = AgentCommand.mark_sent(command, [partition_id: actual_partition], ctx.ash_opts)
        {:ok, command.id}

      {:error, reason} ->
        _ = mark_failed(command, reason, ctx.ash_opts)
        {:error, reason}

      other ->
        _ = mark_failed(command, other, ctx.ash_opts)
        {:error, other}
    end
  end

  def dispatch_for_assignment(partition, agent_id, capability, command_type, payload, opts \\ []) do
    partition = normalize_partition(partition)
    capability = normalize_capability(capability)
    agent_id = normalize_agent_id(agent_id)
    opts = put_assignment_context(opts, partition, capability)

    case agent_id do
      nil ->
        case pick_online_agent(partition, capability) do
          {:ok, picked_agent_id, _pid, _metadata} ->
            dispatch(picked_agent_id, command_type, payload, opts)

          {:error, reason} ->
            {:error, reason}
        end

      agent_id ->
        dispatch(agent_id, command_type, payload, opts)
    end
  end

  def run_mapper_job(job, opts \\ []) do
    seeds =
      opts
      |> Keyword.get(:seeds, [])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    payload =
      %{
        job_id: job.id,
        job_name: job.name
      }
      |> maybe_put(:seeds, seeds)
      |> maybe_put(:trigger_source, Keyword.get(opts, :trigger_source))

    opts =
      add_context(opts, %{
        mapper_job_id: job.id,
        partition_id: job.partition || "default",
        promoted_seeds: seeds
      })

    dispatch_for_assignment(
      job.partition || "default",
      job.agent_id,
      "mapper",
      "mapper.run_job",
      payload,
      opts
    )
  end

  def run_sweep_group(group, opts \\ []) do
    payload = %{sweep_group_id: group.id}

    opts =
      add_context(opts, %{sweep_group_id: group.id, partition_id: group.partition || "default"})

    dispatch_for_assignment(
      group.partition || "default",
      group.agent_id,
      "sweep",
      "sweep.run_group",
      payload,
      opts
    )
  end

  def push_config(agent_id) do
    with {:ok, pid, _metadata} <- lookup_control_session(agent_id),
         {:ok, config} <- AgentConfigGenerator.generate_config(agent_id) do
      response = AgentConfigGenerator.to_proto_response(config)

      case GenServer.call(pid, {:push_config, response}, @send_timeout) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  end

  def push_config_for_type(config_type) do
    capability = capability_for_config_type(config_type)

    list_online_sessions()
    |> Enum.filter(fn session -> capability == nil or capability in session.capabilities end)
    |> Enum.each(fn %{agent_id: agent_id} ->
      case push_config(agent_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("Failed to push config to #{agent_id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp lookup_control_session(agent_id) do
    if registry_available?() do
      lookup_registered_session(agent_id)
    else
      {:error, :registry_unavailable}
    end
  end

  defp lookup_registered_session(agent_id) do
    case ProcessRegistry.lookup({:agent_control, agent_id}) do
      [{pid, metadata}] when is_pid(pid) ->
        ensure_session_alive(pid, metadata, agent_id)

      [] ->
        {:error, {:agent_offline, agent_id}}
    end
  end

  defp ensure_session_alive(pid, metadata, agent_id) do
    if process_alive?(pid) do
      {:ok, pid, metadata || %{}}
    else
      {:error, {:agent_offline, agent_id}}
    end
  end

  defp list_online_sessions do
    if registry_available?() do
      ProcessRegistry.select_by_type(:agent_control)
      |> Enum.map(fn {key, pid, metadata} ->
        agent_id = elem(key, 1)
        metadata = metadata || %{}

        %{
          agent_id: agent_id,
          pid: pid,
          metadata: metadata,
          partition_id: partition_from_metadata(metadata),
          capabilities: capabilities_from_metadata(metadata)
        }
      end)
      |> Enum.filter(fn %{pid: pid} -> process_alive?(pid) end)
    else
      []
    end
  end

  defp pick_online_agent(partition, capability) do
    list_online_sessions()
    |> Enum.filter(fn session ->
      session.partition_id == partition and
        (capability == nil or capability in session.capabilities)
    end)
    |> Enum.sort_by(& &1.agent_id)
    |> case do
      [%{agent_id: agent_id, pid: pid, metadata: metadata} | _] -> {:ok, agent_id, pid, metadata}
      [] -> {:error, :agent_offline}
    end
  end

  defp process_alive?(pid) when is_pid(pid) do
    if node(pid) == node() do
      Process.alive?(pid)
    else
      case :rpc.call(node(pid), Process, :alive?, [pid], 1_000) do
        true -> true
        _ -> false
      end
    end
  end

  defp process_alive?(_), do: false

  defp ensure_assignment(agent_id, metadata, partition, capability) do
    with :ok <- ensure_partition(agent_id, metadata, partition),
         :ok <- ensure_capability(agent_id, metadata, capability) do
      :ok
    end
  end

  defp ensure_partition(_agent_id, _metadata, nil), do: :ok

  defp ensure_partition(agent_id, metadata, partition) do
    agent_partition = partition_from_metadata(metadata)

    if agent_partition == partition do
      :ok
    else
      {:error, {:agent_partition_mismatch, agent_id, agent_partition}}
    end
  end

  defp ensure_capability(_agent_id, _metadata, nil), do: :ok

  defp ensure_capability(agent_id, metadata, capability) do
    capabilities = capabilities_from_metadata(metadata)

    if capability in capabilities do
      :ok
    else
      {:error, {:agent_capability_missing, agent_id, capability}}
    end
  end

  defp encode_payload(nil), do: <<>>
  defp encode_payload(payload) when is_binary(payload), do: payload
  defp encode_payload(payload), do: Jason.encode!(payload)

  defp normalize_payload(nil), do: nil

  defp normalize_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"value" => decoded}
      {:error, _} -> nil
    end
  end

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(payload) when is_list(payload), do: %{"items" => payload}
  defp normalize_payload(payload), do: %{"value" => payload}

  defp normalize_partition(nil), do: "default"
  defp normalize_partition(""), do: "default"
  defp normalize_partition(value), do: value

  defp normalize_agent_id(nil), do: nil

  defp normalize_agent_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_agent_id(value), do: to_string(value)

  defp normalize_capability(nil), do: nil
  defp normalize_capability(value) when is_binary(value), do: String.trim(value)
  defp normalize_capability(value), do: to_string(value)

  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(_), do: %{}

  defp add_context(opts, additions) do
    context =
      opts
      |> Keyword.get(:context, %{})
      |> normalize_context()
      |> Map.merge(additions)

    Keyword.put(opts, :context, context)
  end

  defp put_assignment_context(opts, partition, capability) do
    opts
    |> add_context(%{partition_id: partition, required_capability: capability})
    |> Keyword.put(:required_partition, partition)
    |> Keyword.put(:required_capability, capability)
  end

  defp resolve_partition(opts, required_partition) do
    context = opts |> Keyword.get(:context, %{}) |> normalize_context()

    opts
    |> Keyword.get(
      :partition_id,
      Map.get(context, :partition_id) || Map.get(context, "partition_id") || required_partition
    )
    |> normalize_partition()
  end

  defp build_command_request(command_id, command_type, payload_json, ttl_seconds, created_at) do
    %Monitoring.CommandRequest{
      command_id: command_id,
      command_type: command_type,
      payload_json: payload_json,
      ttl_seconds: ttl_seconds,
      created_at: created_at
    }
  end

  defp build_command_context(context, command, partition_id, created_at) do
    context
    |> Map.put_new(:command_id, command.id)
    |> Map.put_new(:command_type, command.command_type)
    |> Map.put_new(:agent_id, command.agent_id)
    |> Map.put_new(:partition_id, partition_id)
    |> Map.put_new(:created_at, created_at)
  end

  defp requested_by_id(nil), do: nil
  defp requested_by_id(%{id: id}) when is_binary(id), do: id
  defp requested_by_id(%{id: id}), do: to_string(id)
  defp requested_by_id(%{email: email}) when is_binary(email), do: email
  defp requested_by_id(_), do: nil

  defp registry_available? do
    Process.whereis(ProcessRegistry.registry_name()) != nil
  end

  defp partition_from_metadata(metadata) do
    Map.get(metadata, :partition_id) || Map.get(metadata, "partition_id") || "default"
  end

  defp capabilities_from_metadata(metadata) do
    metadata
    |> Map.get(:capabilities, Map.get(metadata, "capabilities", []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp mark_failed(command, reason, ash_opts) do
    AgentCommand.fail(
      command,
      [
        message: failure_message(reason),
        failure_reason: failure_reason(reason)
      ],
      ash_opts
    )
  end

  defp mark_offline(command, reason, ash_opts) do
    AgentCommand.mark_offline(
      command,
      [
        message: failure_message(reason),
        failure_reason: failure_reason(reason)
      ],
      ash_opts
    )
  end

  defp failure_reason({:agent_offline, _}), do: "agent_offline"
  defp failure_reason({:agent_partition_mismatch, _, _}), do: "agent_partition_mismatch"
  defp failure_reason({:agent_capability_missing, _, _}), do: "agent_capability_missing"
  defp failure_reason(:registry_unavailable), do: "registry_unavailable"
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason), do: inspect(reason)

  defp failure_message(reason), do: inspect(reason)

  defp capability_for_config_type(:mapper), do: "mapper"
  defp capability_for_config_type(:sweep), do: "sweep"
  defp capability_for_config_type(:sysmon), do: "sysmon"
  defp capability_for_config_type(:snmp), do: "snmp"
  defp capability_for_config_type(_), do: nil
end
