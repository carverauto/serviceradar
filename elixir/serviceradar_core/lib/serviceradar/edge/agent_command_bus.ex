defmodule ServiceRadar.Edge.AgentCommandBus do
  @moduledoc """
  Dispatches on-demand agent commands over the control stream.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RelaySourceResolver
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandCleanupWorker
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @default_ttl_seconds 60
  @active_mtr_statuses [:queued, :sent, :acknowledged, :running]
  @max_concurrent_on_demand_mtr 2
  @max_concurrent_bulk_mtr_jobs 1
  @send_timeout 5_000

  def dispatch(agent_id, command_type, payload, opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    created_at = System.system_time(:second)
    required_partition = Keyword.get(opts, :required_partition)
    required_capability = Keyword.get(opts, :required_capability)
    source = normalize_source(Keyword.get(opts, :source, :on_demand))
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

    with :ok <- ensure_dispatch_capacity(agent_id, command_type, source, ash_opts),
         {:ok, command} <- AgentCommand.create_command(command_attrs, ash_opts) do
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
    end
  end

  defp dispatch_created_command(command, ctx) do
    persist_command_side_effects(command, ctx)

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

  defp persist_command_side_effects(command, ctx) do
    if ctx.command_type == "mtr.bulk_run" do
      persist_bulk_mtr_targets(command.id, ctx.payload_json)
    end
  end

  defp persist_bulk_mtr_targets(command_id, payload_json) do
    with {:ok, %{"targets" => targets}} <- Jason.decode(payload_json),
         true <- is_list(targets),
         {:ok, command_uuid} <- Ecto.UUID.dump(command_id) do
      now = DateTime.utc_now()

      rows =
        targets
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.map(fn target ->
          %{
            command_id: command_uuid,
            target: target,
            status: "queued",
            inserted_at: now,
            updated_at: now
          }
        end)

      if rows != [] do
        Repo.insert_all("mtr_bulk_job_targets", rows,
          prefix: "platform",
          on_conflict: :nothing,
          conflict_target: [:command_id, :target]
        )
      end
    else
      :error ->
        Logger.warning("Failed to persist bulk MTR queued target rows due to invalid command UUID",
          command_id: inspect(command_id)
        )

      _ -> :ok
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

  def dispatch_bulk_mtr(agent_id, targets, opts \\ []) when is_list(targets) do
    normalized_targets =
      targets
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    payload =
      %{
        "targets" => normalized_targets,
        "protocol" => normalize_mtr_protocol(Keyword.get(opts, :protocol, "icmp")),
        "execution_profile" =>
          normalize_bulk_execution_profile(Keyword.get(opts, :execution_profile, "fast"))
      }
      |> maybe_put("target_query", normalize_optional_string(Keyword.get(opts, :target_query)))
      |> maybe_put("selector_limit", Keyword.get(opts, :selector_limit))
      |> maybe_put("max_hops", Keyword.get(opts, :max_hops))
      |> maybe_put("concurrency", Keyword.get(opts, :concurrency))

    ttl_seconds =
      opts
      |> Keyword.get(:ttl_seconds, bulk_mtr_ttl_seconds(length(normalized_targets)))
      |> max(60)

    dispatch(agent_id, "mtr.bulk_run", payload,
      ttl_seconds: ttl_seconds,
      required_capability: "mtr",
      context: Keyword.get(opts, :context, %{}),
      actor: Keyword.get(opts, :actor)
    )
  end

  def start_camera_relay(agent_id, payload, opts \\ []) do
    payload = normalize_camera_relay_start_payload(payload)

    with {:ok, payload} <- resolve_camera_relay_payload(payload, opts) do
      opts =
        add_context(opts, %{
          relay_session_id: payload.relay_session_id,
          camera_source_id: payload.camera_source_id,
          stream_profile_id: payload.stream_profile_id,
          source_url: payload[:source_url]
        })

      dispatch(agent_id, "camera.open_relay", payload, opts)
    end
  end

  def stop_camera_relay(agent_id, payload, opts \\ []) do
    payload = normalize_camera_relay_stop_payload(payload)

    opts =
      add_context(opts, %{
        relay_session_id: payload.relay_session_id
      })

    dispatch(agent_id, "camera.close_relay", payload, opts)
  end

  def push_config(agent_id) when is_binary(agent_id) do
    with {:ok, pid, _metadata} <- lookup_control_session(agent_id) do
      response = AgentConfigGenerator.generate_proto_response(agent_id)

      case GenServer.call(pid, {:push_config, response}, @send_timeout) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  rescue
    error ->
      {:error, {:database_error, error}}
  end

  def push_config(_agent_id), do: {:error, :invalid_agent_id}

  defp ensure_dispatch_capacity(_agent_id, _command_type, :automation, _ash_opts), do: :ok

  defp ensure_dispatch_capacity(agent_id, "mtr.run", _source, ash_opts) do
    now = DateTime.utc_now()

    query =
      AgentCommand
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(
        expr(
          agent_id == ^agent_id and command_type == "mtr.run" and
            status in ^@active_mtr_statuses and
            (is_nil(expires_at) or expires_at > ^now) and
            fragment("(? ->> 'trigger_mode') IS NULL", context)
        )
      )
      |> Ash.Query.limit(@max_concurrent_on_demand_mtr)
      |> Ash.Query.select([:id])

    case Ash.read(query, ash_opts) do
      {:ok, commands} when length(commands) >= @max_concurrent_on_demand_mtr ->
        {:error, {:agent_busy, :too_many_concurrent_mtr_traces}}

      {:ok, _commands} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to evaluate MTR dispatch capacity",
          agent_id: agent_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp ensure_dispatch_capacity(agent_id, "mtr.bulk_run", _source, ash_opts) do
    now = DateTime.utc_now()

    query =
      AgentCommand
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(
        expr(
          agent_id == ^agent_id and command_type == "mtr.bulk_run" and
            status in ^@active_mtr_statuses and
            (is_nil(expires_at) or expires_at > ^now)
        )
      )
      |> Ash.Query.limit(@max_concurrent_bulk_mtr_jobs)
      |> Ash.Query.select([:id])

    case Ash.read(query, ash_opts) do
      {:ok, commands} when length(commands) >= @max_concurrent_bulk_mtr_jobs ->
        {:error, {:agent_busy, :bulk_mtr_job_running}}

      {:ok, _commands} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to evaluate bulk MTR dispatch capacity",
          agent_id: agent_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp ensure_dispatch_capacity(_agent_id, _command_type, _source, _ash_opts), do: :ok

  defp normalize_source(:automation), do: :automation
  defp normalize_source("automation"), do: :automation
  defp normalize_source(_), do: :on_demand

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

  defp normalize_camera_relay_start_payload(payload) when is_map(payload) do
    %{
      relay_session_id: payload_value(payload, :relay_session_id),
      camera_source_id: payload_value(payload, :camera_source_id),
      stream_profile_id: payload_value(payload, :stream_profile_id),
      lease_token: payload_value(payload, :lease_token)
    }
    |> maybe_put(:source_url, payload_value(payload, :source_url))
    |> maybe_put(:rtsp_transport, payload_value(payload, :rtsp_transport))
    |> maybe_put(:codec_hint, payload_value(payload, :codec_hint))
    |> maybe_put(:container_hint, payload_value(payload, :container_hint))
    |> maybe_put(:insecure_skip_verify, payload_value(payload, :insecure_skip_verify))
  end

  defp normalize_camera_relay_start_payload(_payload), do: %{}

  defp payload_value(payload, key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp normalize_camera_relay_stop_payload(payload) when is_map(payload) do
    relay_session_id =
      Map.get(payload, :relay_session_id) || Map.get(payload, "relay_session_id")

    reason = Map.get(payload, :reason) || Map.get(payload, "reason")

    maybe_put(%{relay_session_id: relay_session_id}, :reason, reason)
  end

  defp normalize_camera_relay_stop_payload(_payload), do: %{}

  defp resolve_camera_relay_payload(payload, opts) do
    RelaySourceResolver.resolve_start_payload(
      payload,
      camera_profile_fetcher: Keyword.get(opts, :camera_profile_fetcher)
    )
  end

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
      {:ok, pid, metadata}
    else
      {:error, {:agent_offline, agent_id}}
    end
  end

  defp list_online_sessions do
    if registry_available?() do
      :agent_control
      |> ProcessRegistry.select_by_type()
      |> Enum.map(&build_online_session/1)
      |> Enum.filter(&valid_online_session?/1)
    else
      []
    end
  end

  defp build_online_session({key, pid, metadata}) do
    agent_id = elem(key, 1)
    metadata = if(is_map(metadata), do: metadata, else: %{})

    %{
      agent_id: agent_id,
      pid: pid,
      metadata: metadata,
      partition_id: partition_from_metadata(metadata),
      capabilities: capabilities_from_metadata(metadata)
    }
  end

  defp valid_online_session?(%{agent_id: agent_id, pid: pid}) do
    is_binary(agent_id) and process_alive?(pid)
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
      if :rpc.call(node(pid), Process, :alive?, [pid], 1_000) do
        true
      else
        false
      end
    end
  end

  defp process_alive?(_), do: false

  defp ensure_assignment(agent_id, metadata, partition, capability) do
    with :ok <- ensure_partition(agent_id, metadata, partition) do
      ensure_capability(agent_id, metadata, capability)
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

  defp bulk_mtr_ttl_seconds(target_count) when is_integer(target_count) and target_count > 0 do
    max(300, target_count * 15)
  end

  defp bulk_mtr_ttl_seconds(_target_count), do: 300

  defp normalize_bulk_execution_profile(value) do
    value =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if value in ["fast", "balanced", "deep"], do: value, else: "fast"
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_mtr_protocol(value) do
    value =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if value in ["icmp", "udp", "tcp"], do: value, else: "icmp"
  end
end
