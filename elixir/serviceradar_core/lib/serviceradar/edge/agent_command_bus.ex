defmodule ServiceRadar.Edge.AgentCommandBus do
  @moduledoc """
  Dispatches on-demand agent commands over the control stream.
  """

  require Logger

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.ProcessRegistry

  @default_ttl_seconds 60
  @send_timeout 5_000

  def dispatch(agent_id, command_type, payload, opts \\ []) do
    with {:ok, pid, metadata} <- lookup_control_session(agent_id) do
      payload_json = encode_payload(payload)
      ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
      created_at = System.system_time(:second)
      command_id = Ash.UUID.generate()

      command = %Monitoring.CommandRequest{
        command_id: command_id,
        command_type: command_type,
        payload_json: payload_json,
        ttl_seconds: ttl_seconds,
        created_at: created_at
      }

      context =
        opts
        |> Keyword.get(:context, %{})
        |> normalize_context()
        |> Map.put_new(:command_id, command_id)
        |> Map.put_new(:command_type, command_type)
        |> Map.put_new(:agent_id, agent_id)
        |> Map.put_new(:partition_id, partition_from_metadata(metadata))
        |> Map.put_new(:created_at, created_at)

      case GenServer.call(pid, {:send_command, command, context}, @send_timeout) do
        {:ok, _} -> {:ok, command_id}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  end

  def dispatch_for_assignment(partition, agent_id, capability, command_type, payload, opts \\ []) do
    partition = normalize_partition(partition)
    capability = normalize_capability(capability)
    agent_id = normalize_agent_id(agent_id)

    case agent_id do
      nil ->
        case pick_online_agent(partition, capability) do
          {:ok, picked_agent_id, _pid, _metadata} ->
            dispatch(picked_agent_id, command_type, payload, opts)

          {:error, reason} ->
            {:error, reason}
        end

      agent_id ->
        with {:ok, _pid, metadata} <- lookup_control_session(agent_id),
             :ok <- ensure_partition(agent_id, metadata, partition),
             :ok <- ensure_capability(agent_id, metadata, capability) do
          dispatch(agent_id, command_type, payload, opts)
        end
    end
  end

  def run_mapper_job(job) do
    payload = %{job_id: job.id, job_name: job.name}

    dispatch_for_assignment(
      job.partition || "default",
      job.agent_id,
      "mapper",
      "mapper.run_job",
      payload,
      context: %{mapper_job_id: job.id}
    )
  end

  def run_sweep_group(group) do
    payload = %{sweep_group_id: group.id}

    dispatch_for_assignment(
      group.partition || "default",
      group.agent_id,
      "sweep",
      "sweep.run_group",
      payload,
      context: %{sweep_group_id: group.id}
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
        :ok -> :ok
        {:error, reason} ->
          Logger.debug("Failed to push config to #{agent_id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp lookup_control_session(agent_id) do
    if registry_available?() do
      case ProcessRegistry.lookup({:agent_control, agent_id}) do
        [{pid, metadata}] when is_pid(pid) ->
          if Process.alive?(pid) do
            {:ok, pid, metadata || %{}}
          else
            {:error, {:agent_offline, agent_id}}
          end

        [] ->
          {:error, {:agent_offline, agent_id}}
      end
    else
      {:error, :registry_unavailable}
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
      |> Enum.filter(fn %{pid: pid} -> Process.alive?(pid) end)
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

  defp capability_for_config_type(:mapper), do: "mapper"
  defp capability_for_config_type(:sweep), do: "sweep"
  defp capability_for_config_type(:sysmon), do: "sysmon"
  defp capability_for_config_type(:snmp), do: "snmp"
  defp capability_for_config_type(_), do: nil
end
