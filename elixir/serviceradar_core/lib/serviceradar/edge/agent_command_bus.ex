defmodule ServiceRadar.Edge.AgentCommandBus do
  @moduledoc """
  Dispatches on-demand agent commands over the control stream.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
  alias ServiceRadar.Automation.LaunchEnvelopes.CommandPayload
  alias ServiceRadar.Camera.RelaySourceResolver
  alias ServiceRadar.ControlRepo
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandCleanupWorker
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadar.SweepJobs.AgentAssignment

  require Logger

  @default_ttl_seconds 60
  @active_command_statuses [:queued, :sent, :acknowledged, :running]
  @max_concurrent_on_demand_mtr 2
  @max_concurrent_bulk_mtr_jobs 1
  @max_concurrent_endpoint_inventory_queries 8
  @max_concurrent_endpoint_inventory_force_fresh 1
  @max_endpoint_inventory_cohort_size 128
  @max_endpoint_inventory_cohort_concurrency 16
  @send_timeout 5_000
  @sweep_dispatch_max_concurrency 8
  @endpoint_inventory_capability "endpoint-inventory"
  @endpoint_inventory_cache_query_type "endpoint_inventory.cache_query"
  @endpoint_inventory_force_fresh_scan_type "endpoint_inventory.force_fresh_scan"
  @endpoint_inventory_cohort_query_type "endpoint_inventory.cohort_cache_query"
  @endpoint_inventory_force_fresh_permission "endpoint_inventory.force_fresh_scan"
  @endpoint_inventory_force_fresh_rate_bucket :endpoint_inventory_force_fresh_scan
  @endpoint_inventory_force_fresh_rate_limit 4
  @endpoint_inventory_force_fresh_rate_window_seconds 300
  @preallocated_callback_command_types [
    "awx.create_callback_credential",
    "awx.fetch_callback_credential",
    "awx.launch_job",
    "awx.fetch_job",
    "awx.list_recent_jobs",
    "awx.fetch_job_host_summaries",
    "awx.cancel_job",
    "awx.delete_callback_credential"
  ]
  @notification_command_type "plugin.run_action"
  @notification_envelope_schema "serviceradar.notification_delivery.v1"
  @callback_command_context_schema "serviceradar.automation_callback_command/v1"
  @secure_execution_command_context_schema "serviceradar.automation_execution_command/v1"
  @secure_execution_command_types [
    "awx.launch_job",
    "awx.fetch_job",
    "awx.list_recent_jobs",
    "awx.fetch_job_host_summaries",
    "awx.cancel_job"
  ]

  def dispatch(agent_id, command_type, payload, opts \\ []) do
    payload_map = normalize_payload(payload)

    with {:ok, command_id} <-
           canonical_optional_command_id(
             command_type,
             Keyword.get(opts, :command_id),
             payload_map
           ),
         :ok <- validate_preallocated_transmit_payload(command_type, payload_map, opts) do
      do_dispatch(agent_id, command_type, payload, opts, command_id)
    end
  end

  defp do_dispatch(agent_id, command_type, payload, opts, command_id) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    created_at = System.system_time(:second)
    required_partition = Keyword.get(opts, :required_partition)
    required_capability = Keyword.get(opts, :required_capability)
    source = normalize_source(Keyword.get(opts, :source, :on_demand))
    context = opts |> Keyword.get(:context, %{}) |> normalize_context()
    required_gateway_node = resolve_required_gateway_node(opts, context)

    case resolve_initial_dispatch_partition(
           agent_id,
           required_gateway_node,
           opts,
           required_partition
         ) do
      {:error, reason} ->
        {:error, reason}

      partition_id ->
        do_dispatch_in_partition(agent_id, command_type, payload, opts, command_id, %{
          partition_id: partition_id,
          ttl_seconds: ttl_seconds,
          created_at: created_at,
          required_partition: required_partition,
          required_capability: required_capability,
          required_gateway_node: required_gateway_node,
          source: source,
          context: context
        })
    end
  end

  defp do_dispatch_in_partition(agent_id, command_type, payload, opts, command_id, dispatch) do
    requested_command_id = Keyword.get(opts, :command_id)
    transmit_payload = Keyword.get(opts, :transmit_payload, payload)
    payload_map = normalize_payload(payload)

    command_attrs =
      maybe_put(
        %{
          command_type: command_type,
          agent_id: agent_id,
          partition_id: dispatch.partition_id,
          payload: payload_map,
          context: dispatch.context,
          ttl_seconds: dispatch.ttl_seconds,
          requested_by: requested_by_id(Keyword.get(opts, :actor))
        },
        :command_id,
        command_id
      )

    ash_opts = [actor: SystemActor.system(:agent_command_bus)]

    with {:ok, command_id} <-
           normalize_preallocated_command_id(command_type, requested_command_id),
         command_attrs = maybe_put(command_attrs, :command_id, command_id),
         :ok <- reject_sensitive_transmit_payload(transmit_payload),
         :ok <- reject_endpoint_inventory_blob_payload(command_type, transmit_payload),
         :ok <- ensure_dispatch_capacity(agent_id, command_type, dispatch.source, ash_opts),
         {:ok, command} <- create_command(command_attrs, ash_opts) do
      _ = AgentCommandCleanupWorker.ensure_scheduled()

      payload_json =
        encode_payload(command_payload_for_transmit(command_type, transmit_payload, command))

      context = command_context_for_transmit(command_type, dispatch.context, command)

      dispatch_created_command(command, %{
        agent_id: agent_id,
        command_type: command_type,
        payload_json: payload_json,
        ttl_seconds: dispatch.ttl_seconds,
        created_at: dispatch.created_at,
        required_partition: dispatch.required_partition,
        required_capability: dispatch.required_capability,
        required_gateway_node: dispatch.required_gateway_node,
        context: context,
        ash_opts: ash_opts
      })
    end
  end

  defp reject_sensitive_transmit_payload(payload) do
    if CredentialRedactor.redact(payload) == payload do
      :ok
    else
      {:error, :sensitive_transmit_payload_denied}
    end
  end

  defp normalize_preallocated_command_id("awx.create_callback_credential", nil),
    do: {:error, :preallocated_command_id_required}

  defp normalize_preallocated_command_id(_command_type, nil), do: {:ok, nil}

  defp normalize_preallocated_command_id(command_type, command_id)
       when command_type in @preallocated_callback_command_types and is_binary(command_id) do
    case Ecto.UUID.cast(command_id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_preallocated_command_id}
    end
  end

  defp normalize_preallocated_command_id(@notification_command_type, command_id)
       when is_binary(command_id) do
    case Ecto.UUID.cast(command_id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_preallocated_command_id}
    end
  end

  defp normalize_preallocated_command_id(_command_type, _command_id),
    do: {:error, :preallocated_command_id_denied}

  defp reject_endpoint_inventory_blob_payload(command_type, payload) do
    if endpoint_inventory_command_type?(command_type) and
         contains_endpoint_inventory_blob_key?(payload) do
      {:error, :endpoint_inventory_command_blob_payload_denied}
    else
      :ok
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

    dispatch_partition =
      command_partition(command) || normalize_optional_string(ctx.required_partition)

    case lookup_control_session(
           ctx.agent_id,
           ctx.required_gateway_node,
           dispatch_partition
         ) do
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
        control_repo().insert_all("mtr_bulk_job_targets", rows,
          prefix: "platform",
          on_conflict: :nothing,
          conflict_target: [:command_id, :target]
        )
      end
    else
      :error ->
        Logger.warning(
          "Failed to persist bulk MTR queued target rows due to invalid command UUID",
          command_id: inspect(command_id)
        )

      _ ->
        :ok
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

    case bind_dispatch_partition(command, actual_partition) do
      :ok ->
        case call_control_session(
               ctx.agent_id,
               pid,
               {:send_command, command_request, command_context},
               metadata
             ) do
          {:ok, _} ->
            _ = mark_sent(command, [partition_id: actual_partition], ctx.ash_opts)
            {:ok, command.id}

          {:error, reason} ->
            _ = mark_failed(command, reason, ctx.ash_opts)
            {:error, reason}

          other ->
            _ = mark_failed(command, other, ctx.ash_opts)
            {:error, other}
        end

      {:error, reason} ->
        _ = mark_failed(command, reason, ctx.ash_opts)
        {:error, reason}
    end
  end

  # Persist the mTLS/control-session partition before bytes can reach the
  # agent. ACK/progress/result handlers compare against this immutable dispatch
  # evidence, so an immediate response cannot race a post-send partition write.
  defp bind_dispatch_partition(command, partition_id)
       when is_binary(partition_id) and partition_id != "" do
    case control_repo().query(
           """
           UPDATE platform.agent_commands
           SET partition_id = $2,
               updated_at = now() AT TIME ZONE 'utc'
           WHERE command_id = $1::text::uuid
             AND status = 'queued'
             AND (partition_id IS NULL OR partition_id = $2)
           RETURNING command_id
           """,
           [command_id(command), partition_id]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _result} -> {:error, :command_dispatch_partition_bind_rejected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_dispatch_partition(_command, _partition_id),
    do: {:error, :command_dispatch_partition_required}

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
    with {:ok, {dispatch_id, dispatch_generation}} <- sweep_dispatch_identity(opts) do
      do_run_sweep_group(group, opts, dispatch_id, dispatch_generation)
    end
  end

  defp do_run_sweep_group(group, opts, dispatch_id, dispatch_generation) do
    payload = %{sweep_group_id: group.id}
    group_partition = group.partition || "default"
    agent_ids = AgentAssignment.normalize(group.agent_ids)
    dispatch_fun = Keyword.get(opts, :dispatch_fun, &dispatch/4)

    opts =
      add_context(opts, %{
        sweep_group_id: group.id,
        device_partition_id: group_partition,
        sweep_dispatch_id: dispatch_id,
        sweep_dispatch_generation: dispatch_generation
      })

    listing_opts =
      Keyword.take(opts, [:registry_present?, :local_registry_reader, :registry_rpc])

    publish_sweep_dispatch(group.id, dispatch_id, dispatch_generation, :started, %{
      commands: [],
      failures: []
    })

    sessions = list_online_sessions(listing_opts)

    result =
      case agent_ids do
        [] ->
          dispatch_sweep_group_to_all(sessions, group_partition, payload, opts, dispatch_fun)

        selected_agent_ids ->
          dispatch_sweep_group_to_selected(
            sessions,
            selected_agent_ids,
            payload,
            opts,
            dispatch_fun
          )
      end

    publish_sweep_dispatch(group.id, dispatch_id, dispatch_generation, :finished, result)
    sweep_dispatch_return(result)
  end

  # All-agents groups compile onto every scanner in the partition. Run now must
  # fan out the same way; picking the first online session by agent_id left the
  # rest of the fleet idle.
  defp dispatch_sweep_group_to_all(sessions, partition, payload, opts, dispatch_fun) do
    case online_agents_for_assignment(sessions, partition, "sweep") do
      [] ->
        %{commands: [], failures: [], error: :agent_offline}

      sessions ->
        sessions
        |> Enum.map(&{:ok, &1})
        |> dispatch_sweep_candidates(payload, opts, dispatch_fun)
        |> collect_sweep_dispatches()
    end
  end

  defp dispatch_sweep_group_to_selected(sessions, agent_ids, payload, opts, dispatch_fun) do
    sessions_by_agent =
      sessions
      |> Enum.filter(& &1.canonical_principal?)
      |> Enum.group_by(& &1.agent_id)

    agent_ids
    |> Enum.map(fn agent_id ->
      case selected_sweep_session(agent_id, sessions_by_agent) do
        {:ok, session} -> {:ok, session}
        {:error, reason} -> {:error, agent_id, reason}
      end
    end)
    |> dispatch_sweep_candidates(payload, opts, dispatch_fun)
    |> collect_sweep_dispatches()
  end

  # A selected UID is authority only through a canonical four-part control key.
  # Legacy agent-only keys remain observable for transition diagnostics, but they
  # cannot select a sweep target or make a canonical principal ambiguous.
  defp selected_sweep_session(agent_id, sessions_by_agent) do
    sessions = Map.get(sessions_by_agent, agent_id, [])

    case sessions |> Enum.map(& &1.partition_id) |> Enum.uniq() do
      [] ->
        {:error, {:agent_offline, agent_id}}

      [partition_id] ->
        with {:ok, evidence} <- resolve_control_session_evidence(partition_id, agent_id, nil),
             :ok <- selected_sweep_capability(agent_id, evidence) do
          {:ok,
           %{
             agent_id: agent_id,
             partition_id: partition_id,
             metadata: evidence
           }}
        end

      _multiple ->
        {:error, {:agent_partition_ambiguous, agent_id}}
    end
  end

  defp selected_sweep_capability(agent_id, %{capabilities: capabilities})
       when is_list(capabilities) do
    if "sweep" in capabilities,
      do: :ok,
      else: {:error, {:agent_capability_missing, agent_id, "sweep"}}
  end

  defp selected_sweep_capability(agent_id, _evidence),
    do: {:error, {:agent_capability_missing, agent_id, "sweep"}}

  defp dispatch_sweep_session(session, payload, opts, dispatch_fun) do
    gateway_node = gateway_node_from_metadata(session.metadata)

    dispatch_opts =
      opts
      |> put_assignment_context(session.partition_id, "sweep")
      |> add_context(%{
        agent_id: session.agent_id,
        member_partition_id: session.partition_id
      })
      |> Keyword.put(:required_gateway_node, gateway_node)

    case dispatch_fun.(session.agent_id, "sweep.run_group", payload, dispatch_opts) do
      {:ok, command_id} -> {:ok, session.agent_id, command_id}
      {:error, reason} -> {:error, session.agent_id, reason}
      other -> {:error, session.agent_id, other}
    end
  end

  defp dispatch_sweep_candidates(candidates, payload, opts, dispatch_fun) do
    dispatch_entries =
      candidates
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:ok, session}, index} -> [{index, session}]
        {{:error, _agent_id, _reason}, _index} -> []
      end)

    max_concurrency = sweep_dispatch_concurrency(opts)

    dispatched_by_index =
      dispatch_entries
      |> Task.async_stream(
        fn {_index, session} ->
          safe_dispatch_sweep_session(session, payload, opts, dispatch_fun)
        end,
        max_concurrency: max_concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.zip(dispatch_entries)
      |> Map.new(fn {task_result, {index, session}} ->
        {index, normalize_sweep_dispatch_task_result(task_result, session.agent_id)}
      end)

    candidates
    |> Enum.with_index()
    |> Enum.map(fn
      {{:ok, _session}, index} -> Map.fetch!(dispatched_by_index, index)
      {{:error, agent_id, reason}, _index} -> {:error, agent_id, reason}
    end)
  end

  defp safe_dispatch_sweep_session(session, payload, opts, dispatch_fun) do
    {:completed, dispatch_sweep_session(session, payload, opts, dispatch_fun)}
  rescue
    exception -> {:task_exit, {:exception, exception.__struct__}}
  catch
    :exit, reason -> {:task_exit, reason}
    kind, _reason -> {:task_exit, kind}
  end

  defp normalize_sweep_dispatch_task_result({:ok, {:completed, result}}, _agent_id), do: result

  defp normalize_sweep_dispatch_task_result({:ok, {:task_exit, reason}}, agent_id),
    do: {:error, agent_id, {:dispatch_task_exit, safe_sweep_dispatch_exit(reason)}}

  defp normalize_sweep_dispatch_task_result({:exit, reason}, agent_id),
    do: {:error, agent_id, {:dispatch_task_exit, safe_sweep_dispatch_exit(reason)}}

  defp safe_sweep_dispatch_exit(reason) when is_atom(reason), do: reason
  defp safe_sweep_dispatch_exit(_reason), do: :abnormal

  defp sweep_dispatch_concurrency(opts) do
    case Keyword.get(opts, :sweep_dispatch_max_concurrency, @sweep_dispatch_max_concurrency) do
      value when is_integer(value) and value > 0 -> min(value, @sweep_dispatch_max_concurrency)
      _invalid -> @sweep_dispatch_max_concurrency
    end
  end

  defp collect_sweep_dispatches(results) do
    commands =
      Enum.flat_map(results, fn
        {:ok, agent_id, command_id} -> [%{agent_id: agent_id, command_id: command_id}]
        _failure -> []
      end)

    failures =
      Enum.flat_map(results, fn
        {:error, agent_id, reason} -> [%{agent_id: agent_id, reason: reason}]
        _success -> []
      end)

    error = if commands == [], do: first_sweep_failure(failures)

    maybe_put(%{commands: commands, failures: failures}, :error, error)
  end

  defp first_sweep_failure([%{reason: reason} | _rest]), do: reason
  defp first_sweep_failure([]), do: :agent_offline

  defp publish_sweep_dispatch(group_id, dispatch_id, dispatch_generation, phase, result) do
    result
    |> Map.put(:sweep_group_id, group_id)
    |> Map.put(:sweep_dispatch_id, dispatch_id)
    |> Map.put(:sweep_dispatch_generation, dispatch_generation)
    |> Map.put(:phase, phase)
    |> AgentCommandPubSub.broadcast_sweep_dispatch()
  end

  defp sweep_dispatch_identity(opts) do
    dispatch_id = Keyword.get_lazy(opts, :sweep_dispatch_id, &Ash.UUIDv7.generate/0)

    allocator =
      Keyword.get(
        opts,
        :sweep_dispatch_generation_allocator,
        &allocate_sweep_dispatch_generation/0
      )

    case call_sweep_dispatch_generation_allocator(allocator) do
      {:ok, generation} -> {:ok, {dispatch_id, generation}}
      {:error, _reason} -> {:error, :sweep_dispatch_generation_unavailable}
    end
  end

  defp allocate_sweep_dispatch_generation do
    case control_repo().query("SELECT txid_current()::text", []) do
      {:ok, %{rows: [[generation]]}} -> {:ok, generation}
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :unexpected_generation_result}
    end
  end

  defp call_sweep_dispatch_generation_allocator(allocator) when is_function(allocator, 0) do
    normalize_sweep_dispatch_generation(allocator.())
  rescue
    _exception -> {:error, :generation_allocator_failed}
  catch
    _kind, _reason -> {:error, :generation_allocator_failed}
  end

  defp call_sweep_dispatch_generation_allocator(_allocator),
    do: {:error, :invalid_generation_allocator}

  defp normalize_sweep_dispatch_generation({:ok, generation}) when is_binary(generation) do
    case Integer.parse(generation) do
      {generation, ""} when generation > 0 -> {:ok, Integer.to_string(generation)}
      _invalid -> {:error, :invalid_generation}
    end
  end

  defp normalize_sweep_dispatch_generation({:error, reason}), do: {:error, reason}
  defp normalize_sweep_dispatch_generation(_unexpected), do: {:error, :invalid_generation_result}

  defp sweep_dispatch_return(%{commands: [], error: reason}), do: {:error, reason}

  defp sweep_dispatch_return(%{commands: commands, failures: failures}) do
    {:ok, %{commands: commands, failures: failures}}
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

  @doc """
  Dispatch an ad-hoc network scan (ICMP/TCP/MTR) to a single agent.

  Runs on the ephemeral `scan.run_adhoc` command path; the agent scans the
  supplied targets with throwaway engine instances and never touches its
  scheduled sweep config. `opts` accepts `:scan_run_id`, `:ports`, `:modes`,
  `:timeout_ms`, `:concurrency`, `:icmp_count`, `:mtr_protocol`,
  `:mtr_max_hops`, plus the usual `:actor`/`:context`/`:ttl_seconds`.
  """
  def dispatch_adhoc_scan(agent_id, targets, opts \\ []) when is_list(targets) do
    normalized_targets =
      targets
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    modes =
      opts
      |> Keyword.get(:modes, ["icmp"])
      |> List.wrap()
      |> Enum.map(&(&1 |> to_string() |> String.downcase()))
      |> Enum.filter(&(&1 in ["icmp", "tcp", "mtr"]))
      |> Enum.uniq()

    ports =
      opts
      |> Keyword.get(:ports, [])
      |> List.wrap()
      |> Enum.map(&normalize_port/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    payload =
      %{
        "targets" => normalized_targets,
        "modes" => modes,
        "ports" => ports
      }
      |> maybe_put("scan_run_id", normalize_optional_string(Keyword.get(opts, :scan_run_id)))
      |> maybe_put("timeout_ms", Keyword.get(opts, :timeout_ms))
      |> maybe_put("concurrency", Keyword.get(opts, :concurrency))
      |> maybe_put("icmp_count", Keyword.get(opts, :icmp_count))
      |> maybe_put("mtr_protocol", normalize_optional_string(Keyword.get(opts, :mtr_protocol)))
      |> maybe_put("mtr_max_hops", Keyword.get(opts, :mtr_max_hops))

    ttl_seconds =
      opts
      |> Keyword.get(:ttl_seconds, adhoc_scan_ttl_seconds(length(normalized_targets), modes))
      |> max(60)

    dispatch(agent_id, "scan.run_adhoc", payload,
      ttl_seconds: ttl_seconds,
      required_capability: "scan.run_adhoc",
      context: Keyword.get(opts, :context, %{}),
      actor: Keyword.get(opts, :actor)
    )
  end

  defp normalize_port(value) do
    port =
      case value do
        v when is_integer(v) -> v
        v when is_binary(v) -> String.to_integer(String.trim(v))
        _ -> nil
      end

    if is_integer(port) and port > 0 and port <= 65_535, do: port
  rescue
    ArgumentError -> nil
  end

  # Budget ~1s/target for ICMP/TCP and ~15s/target when MTR is requested, with a
  # 10-minute ceiling matching the agent's default scan deadline.
  defp adhoc_scan_ttl_seconds(target_count, modes) do
    per_target = if "mtr" in modes, do: 15, else: 1

    (target_count * per_target + 30)
    |> min(600)
    |> max(60)
  end

  def dispatch_endpoint_inventory_cache_query(agent_id, payload, opts \\ [])
      when is_map(payload) do
    payload = normalize_endpoint_inventory_query_payload(payload)

    dispatch(
      agent_id,
      @endpoint_inventory_cache_query_type,
      payload,
      endpoint_inventory_opts(opts)
    )
  end

  def dispatch_endpoint_inventory_cohort_cache_query(payload, opts \\ []) when is_map(payload) do
    query_id = normalize_cohort_query_id(Keyword.get(opts, :query_id))
    response_subject = AgentCommandPubSub.topic(query_id)
    partition = resolve_endpoint_inventory_cohort_partition(opts)
    requested_agent_ids = endpoint_inventory_cohort_agent_ids(payload, opts)
    payload = normalize_endpoint_inventory_cohort_query_payload(payload)

    with {:ok, targets, coverage_seed} <-
           resolve_endpoint_inventory_cohort_targets(partition, requested_agent_ids),
         :ok <- ensure_endpoint_inventory_cohort_cap(coverage_seed.targeted, opts),
         :ok <- subscribe_to_command_topic(query_id) do
      dispatches =
        dispatch_endpoint_inventory_cohort_targets(
          targets,
          payload,
          query_id,
          response_subject,
          opts
        )

      successful_command_ids = successful_cohort_command_ids(dispatches)

      results =
        collect_endpoint_inventory_cohort_results(
          successful_command_ids,
          endpoint_inventory_cohort_timeout_ms(opts)
        )

      {:ok,
       %{
         query_id: query_id,
         command_type: @endpoint_inventory_cohort_query_type,
         response_subject: response_subject,
         results: Map.values(results),
         dispatches: dispatches,
         coverage:
           endpoint_inventory_cohort_coverage(
             coverage_seed,
             dispatches,
             map_size(results)
           )
       }}
    end
  end

  def dispatch_endpoint_inventory_force_fresh_scan(agent_id, payload, opts \\ [])
      when is_map(payload) do
    actor = Keyword.get(opts, :actor)

    with :ok <- authorize_endpoint_inventory_force_fresh(actor),
         :ok <- enforce_endpoint_inventory_force_fresh_rate_limit(agent_id, actor, opts) do
      payload =
        payload
        |> normalize_endpoint_inventory_force_fresh_payload()
        |> Map.put(:authorized, true)

      dispatch(
        agent_id,
        @endpoint_inventory_force_fresh_scan_type,
        payload,
        endpoint_inventory_opts(opts)
      )
    end
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

  def push_config(agent_id)

  def push_config(agent_id) when is_binary(agent_id) do
    with {:ok, partition_id} <- unique_control_partition(agent_id) do
      push_config(partition_id, agent_id)
    end
  end

  def push_config(_agent_id), do: {:error, :invalid_agent_id}

  @doc """
  Pushes configuration to one authenticated `{partition_id, agent_id}` control
  principal.
  """
  def push_config(partition_id, agent_id)

  def push_config(partition_id, agent_id) when is_binary(partition_id) and is_binary(agent_id) do
    with {:ok, pid, metadata} <- lookup_control_session(agent_id, nil, partition_id) do
      # Only re-deliver when the config VERSION actually changed. A dependency
      # write (e.g. a credential-broker grant re-mint that rewrites the assignment
      # row but is stripped from the version hash) must not restart the agent's
      # running plugins — an inventory run longer than the write cadence could
      # never finish. Reuse the same version-aware path the poll uses.
      case AgentConfigGenerator.get_config_if_changed(
             agent_id,
             partition_from_metadata(metadata),
             agent_known_config_version(agent_id)
           ) do
        :not_modified ->
          :ok

        {:ok, config} ->
          response = AgentConfigGenerator.to_proto_response(config)

          case call_control_session(agent_id, pid, {:push_config, response}, metadata) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
            other -> {:error, other}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    error ->
      {:error, {:database_error, error}}
  end

  def push_config(_partition_id, _agent_id), do: {:error, :invalid_edge_principal}

  # The agent's last acknowledged config version — what it is actually running.
  # Used to decide whether a dependency-triggered push would change anything.
  defp agent_known_config_version(agent_id) do
    case ServiceRadar.Infrastructure.Agent.get_by_uid(agent_id,
           actor: SystemActor.system(:agent_command_bus)
         ) do
      {:ok, agent} -> Map.get(agent, :acked_config_version) || ""
      _ -> ""
    end
  end

  def send_console_frame(agent_id, frame, opts \\ [])

  def send_console_frame(agent_id, frame, opts) when is_binary(agent_id) and is_map(frame) do
    required_gateway_node = Keyword.get(opts, :required_gateway_node)
    required_partition = Keyword.get(opts, :required_partition)
    required_session_pid = Keyword.get(opts, :required_control_session_pid)
    required_evidence = Keyword.get(opts, :required_control_evidence)

    case {required_session_pid, required_evidence} do
      {pid, evidence} when is_pid(pid) and is_map(evidence) ->
        call_exact_control_session(pid, {:send_console_frame, frame, evidence})

      {nil, nil} ->
        case lookup_control_session(agent_id, required_gateway_node, required_partition) do
          {:ok, pid, metadata} ->
            call_control_session(agent_id, pid, {:send_console_frame, frame}, metadata)

          {:error, reason} ->
            {:error, reason}
        end

      _incomplete_binding ->
        {:error, :invalid_control_session_binding}
    end
  end

  def send_console_frame(_agent_id, _frame, _opts), do: {:error, :invalid_console_frame}

  @doc """
  Lists agents with an active control stream that can receive commands.

  This intentionally differs from `ServiceRadar.AgentRegistry.find_agents/0`,
  which also includes status-only agents that are visible to the platform but
  cannot receive command-bus requests such as MTR runs.
  """
  @spec list_online_agents() :: [map()]
  def list_online_agents do
    list_online_sessions()
  end

  defp call_control_session(agent_id, pid, request, metadata) do
    GenServer.call(pid, request, @send_timeout)
  catch
    :exit, {:noproc, _} ->
      maybe_unregister_control_session(agent_id, pid, metadata)
      {:error, :control_session_unavailable}

    :exit, {:normal, _} ->
      maybe_unregister_control_session(agent_id, pid, metadata)
      {:error, :control_session_unavailable}

    :exit, reason ->
      maybe_unregister_control_session(agent_id, pid, metadata)
      {:error, {:control_session_exit, reason}}
  end

  defp call_exact_control_session(pid, request) do
    GenServer.call(pid, request, @send_timeout)
  catch
    :exit, {:noproc, _} ->
      {:error, :control_session_unavailable}

    :exit, {:normal, _} ->
      {:error, :control_session_unavailable}

    :exit, reason ->
      {:error, {:control_session_exit, reason}}
  end

  defp ensure_dispatch_capacity(
         agent_id,
         @endpoint_inventory_cache_query_type,
         _source,
         _ash_opts
       ) do
    now = DateTime.utc_now()

    case count_active_commands(
           agent_id,
           @endpoint_inventory_cache_query_type,
           @max_concurrent_endpoint_inventory_queries,
           now
         ) do
      {:ok, count} when count >= @max_concurrent_endpoint_inventory_queries ->
        {:error, {:agent_busy, :too_many_endpoint_inventory_queries}}

      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to evaluate endpoint inventory query dispatch capacity",
          agent_id: agent_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp ensure_dispatch_capacity(
         agent_id,
         @endpoint_inventory_force_fresh_scan_type,
         _source,
         _ash_opts
       ) do
    now = DateTime.utc_now()

    case count_active_commands(
           agent_id,
           @endpoint_inventory_force_fresh_scan_type,
           @max_concurrent_endpoint_inventory_force_fresh,
           now
         ) do
      {:ok, count} when count >= @max_concurrent_endpoint_inventory_force_fresh ->
        {:error, {:agent_busy, :endpoint_inventory_force_fresh_running}}

      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to evaluate endpoint inventory force-fresh dispatch capacity",
          agent_id: agent_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp ensure_dispatch_capacity(_agent_id, _command_type, :automation, _ash_opts), do: :ok

  defp ensure_dispatch_capacity(agent_id, "mtr.run", _source, _ash_opts) do
    now = DateTime.utc_now()

    case count_active_commands(
           agent_id,
           "mtr.run",
           @max_concurrent_on_demand_mtr,
           now,
           "AND (context ->> 'trigger_mode') IS NULL"
         ) do
      {:ok, count} when count >= @max_concurrent_on_demand_mtr ->
        {:error, {:agent_busy, :too_many_concurrent_mtr_traces}}

      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to evaluate MTR dispatch capacity",
          agent_id: agent_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp ensure_dispatch_capacity(agent_id, "mtr.bulk_run", _source, _ash_opts) do
    now = DateTime.utc_now()

    case count_active_commands(agent_id, "mtr.bulk_run", @max_concurrent_bulk_mtr_jobs, now) do
      {:ok, count} when count >= @max_concurrent_bulk_mtr_jobs ->
        {:error, {:agent_busy, :bulk_mtr_job_running}}

      {:ok, _count} ->
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

  defp count_active_commands(agent_id, command_type, limit, now, extra_filter \\ "") do
    sql = """
    SELECT count(*)::integer
    FROM (
      SELECT 1
      FROM platform.agent_commands
      WHERE agent_id = $1
        AND command_type = $2
        AND status = ANY($3::text[])
        AND (expires_at IS NULL OR expires_at > $4)
        #{extra_filter}
      LIMIT $5
    ) active
    """

    statuses = Enum.map(@active_command_statuses, &Atom.to_string/1)

    case control_repo().query(sql, [agent_id, command_type, statuses, now, limit]) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp endpoint_inventory_opts(opts) do
    opts
    |> add_context(%{required_capability: @endpoint_inventory_capability})
    |> Keyword.put(:required_capability, @endpoint_inventory_capability)
  end

  defp normalize_endpoint_inventory_query_payload(payload) do
    reject_nil_values(%{
      schema:
        payload_value(payload, :schema) || "serviceradar.endpoint_inventory.query_request.v1",
      mode: payload_value(payload, :mode) || "exists",
      predicate: normalize_endpoint_inventory_predicate(payload_value(payload, :predicate)),
      limit: payload_value(payload, :limit),
      stale_threshold_seconds: payload_value(payload, :stale_threshold_seconds),
      metadata: normalize_endpoint_inventory_metadata(payload_value(payload, :metadata))
    })
  end

  defp normalize_endpoint_inventory_cohort_query_payload(payload) do
    payload
    |> put_endpoint_inventory_default_mode("count")
    |> normalize_endpoint_inventory_query_payload()
  end

  defp put_endpoint_inventory_default_mode(payload, mode) do
    if payload_value(payload, :mode) do
      payload
    else
      Map.put(payload, :mode, mode)
    end
  end

  defp normalize_endpoint_inventory_force_fresh_payload(payload) do
    query = payload_value(payload, :query)

    reject_nil_values(%{
      schema:
        payload_value(payload, :schema) ||
          "serviceradar.endpoint_inventory.force_fresh_scan_request.v1",
      sources: List.wrap(payload_value(payload, :sources)),
      query: if(is_map(query), do: normalize_endpoint_inventory_query_payload(query)),
      metadata: normalize_endpoint_inventory_metadata(payload_value(payload, :metadata))
    })
  end

  defp normalize_endpoint_inventory_predicate(predicate) when is_map(predicate) do
    reject_nil_values(%{
      package_manager: payload_value(predicate, :package_manager),
      name: payload_value(predicate, :name),
      version: payload_value(predicate, :version),
      architecture: payload_value(predicate, :architecture),
      ecosystem: payload_value(predicate, :ecosystem),
      purl: payload_value(predicate, :purl),
      purl_canonical: payload_value(predicate, :purl_canonical),
      cpe: payload_value(predicate, :cpe)
    })
  end

  defp normalize_endpoint_inventory_predicate(_predicate), do: %{}

  defp normalize_endpoint_inventory_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_endpoint_inventory_metadata(_metadata), do: %{}

  defp normalize_cohort_query_id(nil), do: Ecto.UUID.generate()
  defp normalize_cohort_query_id(""), do: Ecto.UUID.generate()
  defp normalize_cohort_query_id(query_id) when is_binary(query_id), do: query_id
  defp normalize_cohort_query_id(query_id), do: to_string(query_id)

  defp resolve_endpoint_inventory_cohort_partition(opts) do
    opts
    |> Keyword.get(:required_partition, Keyword.get(opts, :partition_id, "default"))
    |> normalize_partition()
  end

  defp endpoint_inventory_cohort_agent_ids(payload, opts) do
    case Keyword.fetch(opts, :agent_ids) do
      {:ok, agent_ids} ->
        normalize_cohort_agent_ids(agent_ids)

      :error ->
        case payload_value(payload, :agent_ids) do
          nil -> :all
          agent_ids -> normalize_cohort_agent_ids(agent_ids)
        end
    end
  end

  defp normalize_cohort_agent_ids(:all), do: :all

  defp normalize_cohort_agent_ids(agent_ids) do
    agent_ids
    |> List.wrap()
    |> Enum.map(&normalize_agent_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve_endpoint_inventory_cohort_targets(partition, :all) do
    targets =
      list_online_sessions()
      |> Enum.filter(&endpoint_inventory_cohort_session?(&1, partition))
      |> Enum.uniq_by(& &1.agent_id)
      |> Enum.sort_by(& &1.agent_id)

    {:ok, targets, %{targeted: length(targets), offline: 0}}
  end

  defp resolve_endpoint_inventory_cohort_targets(partition, requested_agent_ids)
       when is_list(requested_agent_ids) do
    sessions_by_agent =
      list_online_sessions()
      |> Enum.filter(&endpoint_inventory_cohort_session?(&1, partition))
      |> Map.new(fn session -> {session.agent_id, session} end)

    targets =
      Enum.flat_map(requested_agent_ids, fn agent_id ->
        case Map.fetch(sessions_by_agent, agent_id) do
          {:ok, session} -> [session]
          :error -> []
        end
      end)

    {:ok, targets,
     %{
       targeted: length(requested_agent_ids),
       offline: length(requested_agent_ids) - length(targets)
     }}
  end

  defp endpoint_inventory_cohort_session?(session, partition) do
    session.partition_id == partition and @endpoint_inventory_capability in session.capabilities
  end

  defp ensure_endpoint_inventory_cohort_cap(targeted, opts) do
    cap = endpoint_inventory_cohort_cap(opts)

    if targeted > cap do
      {:error,
       {:cohort_too_large,
        %{
          targeted: targeted,
          cap: cap,
          fallback: "Use SRQL persisted inventory or fleet aggregates for larger cohorts"
        }}}
    else
      :ok
    end
  end

  defp endpoint_inventory_cohort_cap(opts) do
    opts
    |> Keyword.get(:cohort_cap, @max_endpoint_inventory_cohort_size)
    |> max(0)
  end

  defp endpoint_inventory_cohort_concurrency(opts) do
    opts
    |> Keyword.get(:cohort_concurrency, @max_endpoint_inventory_cohort_concurrency)
    |> max(1)
  end

  defp endpoint_inventory_cohort_timeout_ms(opts) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    Keyword.get(opts, :timeout_ms, ttl_seconds * 1_000)
  end

  defp subscribe_to_command_topic(query_id) do
    case AgentCommandPubSub.subscribe(query_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pubsub_subscribe_failed, reason}}
    end
  rescue
    exception -> {:error, {:pubsub_subscribe_failed, Exception.message(exception)}}
  end

  defp dispatch_endpoint_inventory_cohort_targets(
         targets,
         payload,
         query_id,
         response_subject,
         opts
       ) do
    targets
    |> Task.async_stream(
      &dispatch_endpoint_inventory_cohort_target(
        &1,
        payload,
        query_id,
        response_subject,
        opts
      ),
      max_concurrency: endpoint_inventory_cohort_concurrency(opts),
      timeout: @send_timeout + 1_000,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, dispatch} -> dispatch
      {:exit, reason} -> %{agent_id: nil, status: :failed, reason: {:dispatch_exit, reason}}
    end)
  end

  defp dispatch_endpoint_inventory_cohort_target(
         session,
         payload,
         query_id,
         response_subject,
         opts
       ) do
    context =
      opts
      |> Keyword.get(:context, %{})
      |> normalize_context()
      |> Map.merge(%{
        cohort_query_id: query_id,
        response_subject: response_subject
      })

    dispatch_opts =
      opts
      |> Keyword.put(:context, context)
      |> Keyword.put(:required_partition, session.partition_id)
      |> Keyword.put(:required_gateway_node, gateway_node_from_metadata(session.metadata))

    case dispatch_endpoint_inventory_cache_query(session.agent_id, payload, dispatch_opts) do
      {:ok, command_id} ->
        %{agent_id: session.agent_id, command_id: command_id, status: :dispatched}

      {:error, reason} ->
        %{agent_id: session.agent_id, status: :failed, reason: reason}
    end
  end

  defp successful_cohort_command_ids(dispatches) do
    dispatches
    |> Enum.flat_map(fn
      %{command_id: command_id, status: :dispatched} ->
        case normalize_cohort_command_id(command_id) do
          nil -> []
          normalized -> [normalized]
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp collect_endpoint_inventory_cohort_results(expected_command_ids, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + max(timeout_ms, 0)
    do_collect_endpoint_inventory_cohort_results(expected_command_ids, deadline, %{})
  end

  defp do_collect_endpoint_inventory_cohort_results(expected_command_ids, deadline, results) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      map_size(results) == MapSet.size(expected_command_ids) ->
        results

      remaining_ms == 0 ->
        results

      true ->
        receive do
          {:command_result, result} when is_map(result) ->
            case normalize_cohort_command_id(cohort_result_command_id(result)) do
              command_id when is_binary(command_id) ->
                if MapSet.member?(expected_command_ids, command_id) do
                  do_collect_endpoint_inventory_cohort_results(
                    expected_command_ids,
                    deadline,
                    Map.put(results, command_id, result)
                  )
                else
                  do_collect_endpoint_inventory_cohort_results(
                    expected_command_ids,
                    deadline,
                    results
                  )
                end

              _ ->
                do_collect_endpoint_inventory_cohort_results(
                  expected_command_ids,
                  deadline,
                  results
                )
            end

          _other ->
            do_collect_endpoint_inventory_cohort_results(expected_command_ids, deadline, results)
        after
          remaining_ms -> results
        end
    end
  end

  defp cohort_result_command_id(result) when is_map(result) do
    Map.get(result, :command_id) || Map.get(result, "command_id")
  end

  defp normalize_cohort_command_id(nil), do: nil

  defp normalize_cohort_command_id(command_id) when is_binary(command_id) do
    case Ecto.UUID.cast(command_id) do
      {:ok, uuid} ->
        uuid

      :error ->
        case Ecto.UUID.load(command_id) do
          {:ok, uuid} -> uuid
          :error -> command_id
        end
    end
  end

  defp normalize_cohort_command_id(_command_id), do: nil

  defp endpoint_inventory_cohort_coverage(coverage_seed, dispatches, answered) do
    dispatch_failures = Enum.count(dispatches, &(&1.status == :failed))
    dispatched = Enum.count(dispatches, &(&1.status == :dispatched))
    expired = max(dispatched - answered, 0)

    %{
      targeted: coverage_seed.targeted,
      answered: answered,
      offline: coverage_seed.offline + dispatch_failures,
      expired: expired,
      pending: 0,
      complete?:
        answered + coverage_seed.offline + dispatch_failures == coverage_seed.targeted and
          expired == 0
    }
  end

  defp authorize_endpoint_inventory_force_fresh(actor) do
    if RBAC.has_permission?(actor, @endpoint_inventory_force_fresh_permission) do
      :ok
    else
      {:error, :endpoint_inventory_force_fresh_unauthorized}
    end
  end

  defp enforce_endpoint_inventory_force_fresh_rate_limit(agent_id, actor, opts) do
    limit = Keyword.get(opts, :force_fresh_rate_limit, @endpoint_inventory_force_fresh_rate_limit)

    window_seconds =
      Keyword.get(
        opts,
        :force_fresh_rate_window_seconds,
        @endpoint_inventory_force_fresh_rate_window_seconds
      )

    case RateLimiter.check_and_record(
           @endpoint_inventory_force_fresh_rate_bucket,
           {agent_id, requested_by_id(actor)},
           limit: limit,
           window_seconds: window_seconds
         ) do
      :ok ->
        :ok

      {:error, retry_after_seconds} ->
        {:error,
         {:rate_limited, @endpoint_inventory_force_fresh_rate_bucket, retry_after_seconds}}
    end
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp resolve_camera_relay_payload(payload, opts) do
    RelaySourceResolver.resolve_start_payload(
      payload,
      camera_profile_fetcher: Keyword.get(opts, :camera_profile_fetcher)
    )
  end

  defp lookup_control_session(agent_id, required_gateway_node, required_partition) do
    if registry_available?() do
      lookup_registered_session(agent_id, required_gateway_node, required_partition)
    else
      {:error, :registry_unavailable}
    end
  end

  # An agent id is not an authority boundary. Legacy callers may use it only to
  # enumerate the live partitions; selection is then repeated through the exact
  # partition-scoped registry lookup. Multiple partitions fail closed.
  defp lookup_registered_session(agent_id, required_gateway_node, nil) do
    with {:ok, partition_id} <- unique_control_partition(agent_id) do
      lookup_registered_session(agent_id, required_gateway_node, partition_id)
    end
  end

  defp lookup_registered_session(agent_id, required_gateway_node, partition_id)
       when is_binary(partition_id) do
    case normalize_optional_string(partition_id) do
      nil ->
        {:error, :authenticated_partition_required}

      partition_id ->
        partition_id
        |> lookup_control_session_entries(agent_id)
        |> pick_control_session(partition_id, agent_id, required_gateway_node)
    end
  end

  defp lookup_registered_session(_agent_id, _required_gateway_node, _partition_id),
    do: {:error, :authenticated_partition_required}

  @doc false
  def lookup_control_session_entries(partition_id, agent_id)
      when is_binary(partition_id) and is_binary(agent_id) do
    if ProcessRegistry.registry_present?() do
      ProcessRegistry.lookup_agent_control(partition_id, agent_id)
    else
      registry_rpc(:lookup_agent_control, [partition_id, agent_id])
    end
  rescue
    error ->
      Logger.warning(
        "[AgentCommandBus] exact control-session lookup RPC failed: #{inspect(error)}"
      )

      []
  end

  def lookup_control_session_entries(_partition_id, _agent_id), do: []

  @doc false
  # Fleet enumeration only. Never select a command/evidence authority directly
  # from this result; use lookup_control_session_entries/2 after choosing a
  # server-owned partition.
  def lookup_control_session_entries(agent_id) when is_binary(agent_id) do
    list_control_session_entries(agent_id)
  end

  def lookup_control_session_entries(_agent_id), do: []

  @doc false
  def list_control_session_entries(agent_id) when is_binary(agent_id) do
    if ProcessRegistry.registry_present?() do
      ProcessRegistry.list_agent_controls(agent_id)
    else
      registry_rpc(:list_agent_controls, [agent_id])
    end
  rescue
    error ->
      Logger.warning(
        "[AgentCommandBus] control-session enumeration RPC failed: #{inspect(error)}"
      )

      []
  end

  def list_control_session_entries(_agent_id), do: []

  defp registry_rpc(function, args) do
    ProcessRegistry.registry_nodes()
    |> Task.async_stream(
      &registry_rpc_call(&1, function, args),
      ordered: false,
      max_concurrency: 8,
      timeout: 5_500,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, entries} when is_list(entries) -> entries
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp registry_rpc_call(node, function, args) do
    case :erpc.call(node, ProcessRegistry, function, args, 5_000) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp unique_control_partition(agent_id) when is_binary(agent_id) do
    partitions =
      agent_id
      |> list_control_session_entries()
      |> Enum.reduce(MapSet.new(), fn entry, partitions ->
        case control_entry_partition(entry, agent_id) do
          {:ok, partition_id} -> MapSet.put(partitions, partition_id)
          :error -> partitions
        end
      end)
      |> MapSet.to_list()

    case partitions do
      [partition_id] -> {:ok, partition_id}
      [] -> {:error, {:agent_offline, agent_id}}
      _multiple -> {:error, {:agent_partition_ambiguous, agent_id}}
    end
  end

  defp unique_control_partition(_agent_id), do: {:error, :invalid_agent_id}

  defp control_entry_partition({pid, metadata}, agent_id) when is_pid(pid) and is_map(metadata) do
    partition_id = partition_from_metadata(metadata)

    if process_alive?(pid) and agent_from_metadata(metadata) == agent_id and
         is_binary(partition_id) do
      {:ok, partition_id}
    else
      :error
    end
  end

  defp control_entry_partition(_entry, _agent_id), do: :error

  def resolve_control_gateway_node(agent_id, preferred_gateway_node \\ nil)

  def resolve_control_gateway_node(agent_id, preferred_gateway_node) when is_binary(agent_id) do
    case resolve_control_session_evidence(agent_id, preferred_gateway_node) do
      {:ok, evidence} -> {:ok, evidence.gateway_node}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_control_gateway_node(_agent_id, _preferred_gateway_node),
    do: {:error, :invalid_agent_id}

  def resolve_control_gateway_node(partition_id, agent_id, preferred_gateway_node)
      when is_binary(partition_id) and is_binary(agent_id) do
    case resolve_control_session_evidence(partition_id, agent_id, preferred_gateway_node) do
      {:ok, evidence} -> {:ok, evidence.gateway_node}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_control_gateway_node(_partition_id, _agent_id, _preferred_gateway_node),
    do: {:error, :invalid_edge_principal}

  @doc """
  Returns evidence observed by the authenticated agent control stream.

  The registry metadata is written by the gateway session after mTLS identity
  verification; callers must not substitute browser, plugin-result, or console
  payload fields for this evidence.
  """
  def resolve_control_session_evidence(agent_id, preferred_gateway_node \\ nil)

  def resolve_control_session_evidence(agent_id, preferred_gateway_node)
      when is_binary(agent_id) do
    with {:ok, partition_id} <- unique_control_partition(agent_id) do
      resolve_control_session_evidence(partition_id, agent_id, preferred_gateway_node)
    end
  end

  def resolve_control_session_evidence(_agent_id, _preferred_gateway_node),
    do: {:error, :invalid_agent_id}

  @doc """
  Returns control evidence for one exact certificate-derived edge principal.

  The partition is supplied by server-owned assignment/session state. Browser,
  plugin-result, and console payload fields are never accepted as authority.
  """
  def resolve_control_session_evidence(partition_id, agent_id, preferred_gateway_node)
      when is_binary(partition_id) and is_binary(agent_id) do
    # The preferred node is a HINT (where the source was last relayed), not a
    # hard requirement: if the agent's control session has since moved to a
    # different gateway node (agent reconnect, gateway pod roll), return the
    # CURRENT node so callers (e.g. RelaySessionManager) can re-pin and update
    # the stored assignment. Treating the hint as a strict filter made every
    # relay open fail {:agent_offline, ...} forever once the stored
    # assigned_gateway_id went stale.
    case lookup_control_session(agent_id, preferred_gateway_node, partition_id) do
      {:ok, pid, metadata} ->
        {:ok, control_session_evidence(pid, metadata)}

      {:error, {:agent_offline, _}} when not is_nil(preferred_gateway_node) ->
        case lookup_control_session(agent_id, nil, partition_id) do
          {:ok, pid, metadata} -> {:ok, control_session_evidence(pid, metadata)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resolve_control_session_evidence(_partition_id, _agent_id, _preferred_gateway_node),
    do: {:error, :invalid_edge_principal}

  defp control_session_evidence(pid, metadata) when is_pid(pid) and is_map(metadata) do
    %{
      control_session_pid: pid,
      agent_id: Map.get(metadata, :agent_id) || Map.get(metadata, "agent_id"),
      partition_id: partition_from_metadata(metadata),
      gateway_node: gateway_node_from_metadata(metadata),
      capabilities: capabilities_from_metadata(metadata),
      config_version: Map.get(metadata, :config_version) || Map.get(metadata, "config_version"),
      pending_config_version:
        Map.get(metadata, :pending_config_version) ||
          Map.get(metadata, "pending_config_version"),
      applied_plugin_assignments:
        Map.get(metadata, :applied_plugin_assignments) ||
          Map.get(metadata, "applied_plugin_assignments") || []
    }
  end

  defp control_session_evidence(_pid, _metadata) do
    %{
      control_session_pid: nil,
      agent_id: nil,
      partition_id: nil,
      gateway_node: nil,
      capabilities: [],
      config_version: nil,
      pending_config_version: nil,
      applied_plugin_assignments: []
    }
  end

  defp pick_control_session(entries, partition_id, agent_id, required_gateway_node) do
    entries
    |> Enum.uniq_by(fn {pid, metadata} -> {pid, gateway_node_from_metadata(metadata)} end)
    |> Enum.filter(&valid_control_session_entry?(&1, partition_id, agent_id))
    |> Enum.filter(&required_gateway_node_match?(&1, required_gateway_node))
    |> Enum.sort_by(fn {_pid, metadata} ->
      control_session_preference(metadata, required_gateway_node)
    end)
    |> case do
      [{pid, metadata} | _] -> {:ok, pid, metadata}
      [] -> {:error, {:agent_offline, agent_id}}
    end
  end

  defp required_gateway_node_match?(_entry, nil), do: true

  defp required_gateway_node_match?({_pid, metadata}, required_gateway_node),
    do: gateway_node_from_metadata(metadata) == required_gateway_node

  defp control_session_preference(metadata, required_gateway_node) do
    cond do
      is_nil(required_gateway_node) -> 1
      gateway_node_from_metadata(metadata) == required_gateway_node -> 0
      true -> 2
    end
  end

  defp valid_control_session_entry?({pid, metadata}, partition_id, agent_id)
       when is_pid(pid) and is_map(metadata) do
    principal_matches? =
      agent_from_metadata(metadata) == agent_id and
        partition_from_metadata(metadata) == partition_id

    if principal_matches? and process_alive?(pid) do
      true
    else
      maybe_unregister_control_session(agent_id, pid, metadata)
      false
    end
  end

  defp valid_control_session_entry?(_entry, _partition_id, _agent_id), do: false

  defp list_online_sessions, do: list_online_sessions([])

  defp list_online_sessions(opts) do
    :agent_control
    |> control_session_registry_entries(opts)
    |> Enum.uniq_by(&control_session_registry_entry_identity/1)
    |> Enum.map(&build_online_session/1)
    |> Enum.filter(&valid_online_session?/1)
  end

  # web-ng deliberately does not join the Horde registry. Keep unassigned
  # command selection on the same remote-read path as exact, assigned-agent
  # lookup so a live mapper session on a gateway remains discoverable there.
  defp control_session_registry_entries(type, opts) do
    registry_present? =
      Keyword.get_lazy(opts, :registry_present?, &ProcessRegistry.registry_present?/0)

    if registry_present? do
      local_reader =
        Keyword.get(opts, :local_registry_reader, &ProcessRegistry.select_by_type/1)

      local_reader.(type)
    else
      remote_reader = Keyword.get(opts, :registry_rpc, &registry_rpc/2)
      remote_reader.(:select_by_type, [type])
    end
  rescue
    error ->
      Logger.warning(
        "[AgentCommandBus] control-session registry enumeration failed: #{inspect(error)}"
      )

      []
  end

  # Every registry host may return the same CRDT entry over RPC. Preserve
  # distinct replacement pids for a key, but collapse repeated snapshots of
  # the same session even when metadata convergence is briefly out of sync.
  defp control_session_registry_entry_identity({key, pid, _metadata}), do: {key, pid}
  defp control_session_registry_entry_identity(entry), do: entry

  defp build_online_session(
         {{:agent_control, partition_id, agent_id, _gateway_node} = key, pid, metadata}
       )
       when is_binary(partition_id) and is_binary(agent_id) and is_map(metadata) do
    %{
      key: key,
      agent_id: agent_id,
      pid: pid,
      metadata: metadata,
      partition_id: partition_id,
      capabilities: capabilities_from_metadata(metadata),
      canonical_principal?:
        agent_from_metadata(metadata) == agent_id and
          partition_from_metadata(metadata) == partition_id
    }
  end

  defp build_online_session({{:agent_control, agent_id, _node} = key, pid, metadata})
       when is_binary(agent_id) and is_map(metadata) do
    build_legacy_online_session(key, pid, metadata, agent_id)
  end

  defp build_online_session({{:agent_control, agent_id} = key, pid, metadata})
       when is_binary(agent_id) and is_map(metadata) do
    build_legacy_online_session(key, pid, metadata, agent_id)
  end

  defp build_online_session(_entry), do: nil

  defp build_legacy_online_session(key, pid, metadata, agent_id) do
    %{
      key: key,
      agent_id: agent_id,
      pid: pid,
      metadata: metadata,
      partition_id: partition_from_metadata(metadata),
      capabilities: capabilities_from_metadata(metadata),
      canonical_principal?: false
    }
  end

  defp valid_online_session?(%{
         agent_id: agent_id,
         partition_id: partition_id,
         pid: pid,
         key: key
       }) do
    alive? = is_binary(agent_id) and is_binary(partition_id) and process_alive?(pid)

    if !alive? do
      maybe_unregister_local(key)
    end

    alive?
  end

  defp valid_online_session?(_session), do: false

  defp pick_online_agent(partition, capability), do: pick_online_agent(partition, capability, [])

  @doc false
  def pick_online_agent(partition, capability, opts) when is_list(opts) do
    case list_online_agents_for_assignment(partition, capability, opts) do
      [%{agent_id: agent_id, pid: pid, metadata: metadata} | _] ->
        {:ok, agent_id, pid, metadata}

      [] ->
        {:error, :agent_offline}
    end
  end

  @doc false
  def list_online_agents_for_assignment(partition, capability, opts \\ []) do
    opts
    |> list_online_sessions()
    |> online_agents_for_assignment(partition, capability)
  end

  defp online_agents_for_assignment(sessions, partition, capability) do
    sessions
    |> Enum.filter(fn session ->
      session.canonical_principal? and session.partition_id == partition and
        (capability == nil or capability in session.capabilities)
    end)
    |> Enum.uniq_by(& &1.agent_id)
    |> Enum.sort_by(& &1.agent_id)
  end

  defp process_alive?(pid) when is_pid(pid) do
    if node(pid) == node() do
      Process.alive?(pid)
    else
      case :rpc.call(node(pid), Process, :alive?, [pid], 1_000) do
        true -> true
        _unavailable_or_dead -> false
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

  defp resolve_required_gateway_node(opts, context) do
    Enum.find_value(
      [
        Keyword.get(opts, :required_gateway_node),
        Keyword.get(opts, :gateway_node),
        Map.get(context, :required_gateway_node),
        Map.get(context, "required_gateway_node"),
        Map.get(context, :gateway_node),
        Map.get(context, "gateway_node")
      ],
      &normalize_optional_string/1
    )
  end

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

  # Seed an online command with the authenticated control-session partition so
  # the subsequent monotonic pre-send bind can only confirm that tuple. If the
  # session moves partitions between this lookup and dispatch, binding fails
  # closed and no bytes are sent. Offline lifecycle records retain the existing
  # server-side required/default partition because they cannot yield a result.
  defp resolve_initial_dispatch_partition(
         agent_id,
         required_gateway_node,
         opts,
         required_partition
       ) do
    evidence_result =
      case requested_partition(opts, required_partition) do
        nil ->
          resolve_control_session_evidence(agent_id, required_gateway_node)

        partition_id ->
          resolve_control_session_evidence(partition_id, agent_id, required_gateway_node)
      end

    case evidence_result do
      {:ok, %{partition_id: partition_id}}
      when is_binary(partition_id) and partition_id != "" ->
        partition_id

      {:error, {:agent_partition_ambiguous, _agent_id}} = error ->
        error

      _unavailable ->
        resolve_partition(opts, required_partition)
    end
  end

  defp requested_partition(opts, required_partition) do
    context = opts |> Keyword.get(:context, %{}) |> normalize_context()

    Enum.find_value(
      [
        required_partition,
        Keyword.get(opts, :partition_id),
        Map.get(context, :partition_id),
        Map.get(context, "partition_id")
      ],
      &normalize_optional_string/1
    )
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

  defp command_context_for_transmit(command_type, context, command) do
    if endpoint_inventory_command_type?(command_type) do
      Map.put_new(context, :response_subject, command_response_subject(command.id))
    else
      context
    end
  end

  defp command_payload_for_transmit(command_type, payload, command) do
    if endpoint_inventory_command_type?(command_type) do
      metadata =
        payload
        |> payload_value(:metadata)
        |> normalize_endpoint_inventory_metadata()
        |> Map.put_new("response_subject", command_response_subject(command.id))

      Map.put(payload, :metadata, metadata)
    else
      payload
    end
  end

  defp command_response_subject(command_id), do: "#{AgentCommandPubSub.topic(command_id)}"

  defp endpoint_inventory_command_type?(@endpoint_inventory_cache_query_type), do: true
  defp endpoint_inventory_command_type?(@endpoint_inventory_force_fresh_scan_type), do: true
  defp endpoint_inventory_command_type?(_command_type), do: false

  defp contains_endpoint_inventory_blob_key?(payload) when is_map(payload) do
    Enum.any?(payload, fn {key, value} ->
      (endpoint_inventory_blob_key?(key) and present_blob_value?(value)) or
        contains_endpoint_inventory_blob_key?(value)
    end)
  end

  defp contains_endpoint_inventory_blob_key?(payload) when is_list(payload) do
    Enum.any?(payload, &contains_endpoint_inventory_blob_key?/1)
  end

  defp contains_endpoint_inventory_blob_key?(_payload), do: false

  defp endpoint_inventory_blob_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> Kernel.in(["sbom", "bom", "artifact_bytes", "artifact_json", "artifact_payload"])
  end

  defp present_blob_value?(nil), do: false
  defp present_blob_value?(""), do: false
  defp present_blob_value?([]), do: false
  defp present_blob_value?(%{} = value), do: map_size(value) > 0
  defp present_blob_value?(_value), do: true

  defp registry_available? do
    ProcessRegistry.registry_present?() or ProcessRegistry.registry_nodes() != []
  end

  # web-ng left the Horde mesh (`join_process_registry: false`), so it must only
  # prune registry entries when it actually holds the local CRDT. A core node owns
  # the writes; web-ng RPCs its reads and never unregisters remote entries.
  defp maybe_unregister_local(key) do
    if ProcessRegistry.registry_present?() do
      ProcessRegistry.unregister(key)
    end

    :ok
  end

  defp maybe_unregister_control_session(agent_id, pid, metadata) do
    partition_id = partition_from_metadata(metadata)

    if is_binary(agent_id) and is_binary(partition_id) and is_pid(pid) do
      maybe_unregister_local({:agent_control, partition_id, agent_id, node(pid)})
    else
      :ok
    end
  end

  defp partition_from_metadata(metadata) do
    metadata
    |> Map.get(:partition_id, Map.get(metadata, "partition_id"))
    |> normalize_optional_string()
  end

  defp agent_from_metadata(metadata) do
    metadata
    |> Map.get(:agent_id, Map.get(metadata, "agent_id"))
    |> normalize_optional_string()
  end

  defp gateway_node_from_metadata(metadata) do
    Map.get(metadata, :gateway_node) || Map.get(metadata, "gateway_node")
  end

  defp capabilities_from_metadata(metadata) do
    metadata
    |> Map.get(:capabilities, Map.get(metadata, "capabilities", []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp command_partition(command) when is_map(command) do
    command
    |> Map.get(:partition_id, Map.get(command, "partition_id"))
    |> normalize_optional_string()
  end

  defp command_partition(_command), do: nil

  defp mark_failed(command, reason, ash_opts) do
    if control_repo_available?() do
      update_command_status(
        command,
        "failed",
        [
          message: failure_message(reason),
          failure_reason: failure_reason(reason),
          completed_at: DateTime.utc_now()
        ],
        from: ["queued", "sent", "acknowledged", "running"]
      )
    else
      AgentCommand.fail(
        command,
        [
          message: failure_message(reason),
          failure_reason: failure_reason(reason)
        ],
        ash_opts
      )
    end
  end

  defp mark_offline(command, reason, ash_opts) do
    if control_repo_available?() do
      update_command_status(
        command,
        "offline",
        [
          message: failure_message(reason),
          failure_reason: failure_reason(reason),
          completed_at: DateTime.utc_now()
        ],
        from: ["queued", "sent"]
      )
    else
      AgentCommand.mark_offline(
        command,
        [
          message: failure_message(reason),
          failure_reason: failure_reason(reason)
        ],
        ash_opts
      )
    end
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
  defp capability_for_config_type(:bumblebee), do: "bumblebee"
  defp capability_for_config_type(:endpoint_inventory), do: "endpoint-inventory"
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

  defp create_command(attrs, ash_opts) do
    if control_repo_available?() do
      command_id = Map.get(attrs, :command_id) || Ecto.UUID.generate()
      ttl_seconds = Map.get(attrs, :ttl_seconds) || 60

      expires_at =
        Map.get(attrs, :expires_at) || DateTime.add(DateTime.utc_now(), ttl_seconds, :second)

      case control_repo().query(
             """
             INSERT INTO platform.agent_commands (
               command_id,
               command_type,
               agent_id,
               partition_id,
               status,
               payload,
               context,
               ttl_seconds,
               expires_at,
               requested_by,
               inserted_at,
               updated_at
             )
             VALUES (
               $1::text::uuid,
               $2,
               $3,
               $4,
               'queued',
               $5::jsonb,
               $6::jsonb,
               $7,
               $8,
               $9,
               now() AT TIME ZONE 'utc',
               now() AT TIME ZONE 'utc'
             )
             RETURNING command_id::text
             """,
             [
               command_id,
               Map.fetch!(attrs, :command_type),
               Map.fetch!(attrs, :agent_id),
               Map.get(attrs, :partition_id) || "default",
               json_param(Map.get(attrs, :payload)),
               json_param(Map.get(attrs, :context) || %{}),
               ttl_seconds,
               expires_at,
               Map.get(attrs, :requested_by)
             ]
           ) do
        {:ok, %{rows: [[id]]}} ->
          {:ok,
           %{
             id: id,
             command_type: Map.fetch!(attrs, :command_type),
             agent_id: Map.fetch!(attrs, :agent_id),
             partition_id: Map.get(attrs, :partition_id) || "default"
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case Map.get(attrs, :command_id) do
        nil ->
          AgentCommand.create_command(attrs, ash_opts)

        command_id ->
          AgentCommand
          |> Ash.Changeset.for_create(:create_with_id, Map.put(attrs, :command_id, command_id))
          |> Ash.create(ash_opts)
      end
    end
  end

  defp canonical_optional_command_id("awx.create_callback_credential", nil, _payload),
    do: {:error, :preallocated_command_id_required}

  defp canonical_optional_command_id(_command_type, nil, _payload), do: {:ok, nil}

  defp canonical_optional_command_id("awx.create_callback_credential", value, payload)
       when is_binary(value) do
    with {:ok, command_id} <- canonical_command_id(value),
         {:ok, _reference} <- CommandPayload.parse(payload) do
      {:ok, command_id}
    end
  end

  defp canonical_optional_command_id("awx.create_callback_credential", _value, _payload),
    do: {:error, :invalid_command_id}

  defp canonical_optional_command_id(command_type, value, _payload)
       when command_type in @preallocated_callback_command_types and is_binary(value),
       do: canonical_command_id(value)

  defp canonical_optional_command_id(@notification_command_type, value, _payload)
       when is_binary(value),
       do: canonical_command_id(value)

  defp canonical_optional_command_id(_command_type, _value, _payload),
    do: {:error, :preallocated_command_id_not_allowed}

  defp canonical_command_id(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, command_id} -> {:ok, command_id}
      :error -> {:error, :invalid_command_id}
    end
  end

  defp validate_preallocated_transmit_payload(command_type, payload, opts)
       when command_type in @preallocated_callback_command_types do
    context = opts |> Keyword.get(:context, %{}) |> normalize_context()

    cond do
      Keyword.get(opts, :callback_command_attempt) == true ->
        with true <- is_binary(Keyword.get(opts, :command_id)),
             true <- normalize_source(Keyword.get(opts, :source, :on_demand)) == :automation,
             true <- context["schema"] == @callback_command_context_schema,
             true <- context["verb"] == command_type,
             :ok <- reject_callback_transmit_override(command_type, payload, opts) do
          :ok
        else
          false -> {:error, :preallocated_callback_attempt_context_required}
          {:error, _reason} = error -> error
        end

      Keyword.get(opts, :secure_execution_attempt) == true ->
        with true <- command_type in @secure_execution_command_types,
             true <- is_binary(Keyword.get(opts, :command_id)),
             true <- normalize_source(Keyword.get(opts, :source, :on_demand)) == :automation,
             true <- context["schema"] == @secure_execution_command_context_schema,
             true <- context["verb"] == command_type,
             true <-
               context["stage"] in ~w(launch_job fetch_job list_recent_jobs fetch_host_summaries cancel_job),
             false <- Map.has_key?(context, "callback_grant_id") do
          :ok
        else
          _ -> {:error, :preallocated_secure_execution_attempt_context_required}
        end

      not is_nil(Keyword.get(opts, :command_id)) ->
        {:error, :preallocated_callback_attempt_context_required}

      command_type == "awx.create_callback_credential" ->
        {:error, :preallocated_callback_attempt_context_required}

      true ->
        :ok
    end
  end

  defp validate_preallocated_transmit_payload(@notification_command_type, payload, opts) do
    context = opts |> Keyword.get(:context, %{}) |> normalize_context()
    command_id = Keyword.get(opts, :command_id)

    cond do
      Keyword.get(opts, :notification_delivery_attempt) == true ->
        with true <- is_binary(command_id),
             true <- normalize_source(Keyword.get(opts, :source, :on_demand)) == :automation,
             true <- payload["schema"] == @notification_envelope_schema,
             delivery_id when is_binary(delivery_id) and delivery_id != "" <-
               payload["delivery_id"],
             true <- context["notification_delivery_id"] == delivery_id do
          :ok
        else
          _ -> {:error, :preallocated_notification_attempt_context_required}
        end

      not is_nil(command_id) ->
        {:error, :preallocated_notification_attempt_context_required}

      true ->
        :ok
    end
  end

  defp validate_preallocated_transmit_payload(_command_type, _payload, _opts), do: :ok

  defp reject_callback_transmit_override("awx.create_callback_credential", payload, opts) do
    case Keyword.fetch(opts, :transmit_payload) do
      :error ->
        :ok

      {:ok, transmit_payload} ->
        if normalize_payload(transmit_payload) == payload,
          do: :ok,
          else: {:error, :callback_credential_payload_override_forbidden}
    end
  end

  defp reject_callback_transmit_override(_command_type, _payload, _opts), do: :ok

  defp mark_sent(command, attrs, _ash_opts) do
    update_command_status(
      command,
      "sent",
      [partition_id: Keyword.get(attrs, :partition_id), sent_at: DateTime.utc_now()],
      from: ["queued"]
    )
  end

  defp update_command_status(command, status, attrs, opts) do
    command_id = command_id(command)
    from_statuses = Keyword.fetch!(opts, :from)

    case control_repo().query(
           """
           UPDATE platform.agent_commands
           SET
             status = $2,
             partition_id = COALESCE($3, partition_id),
             sent_at = COALESCE($4, sent_at),
             completed_at = COALESCE($5, completed_at),
             message = COALESCE($6, message),
             failure_reason = COALESCE($7, failure_reason),
             updated_at = now() AT TIME ZONE 'utc'
           WHERE command_id = $1::text::uuid
             AND status = ANY($8::text[])
           """,
           [
             command_id,
             status,
             Keyword.get(attrs, :partition_id),
             Keyword.get(attrs, :sent_at),
             Keyword.get(attrs, :completed_at),
             Keyword.get(attrs, :message),
             Keyword.get(attrs, :failure_reason),
             from_statuses
           ]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp command_id(%{id: id}), do: id

  defp json_param(nil), do: nil
  defp json_param(value), do: value

  defp control_repo_available?, do: Process.whereis(ControlRepo) != nil

  defp control_repo do
    if Process.whereis(ControlRepo) do
      ControlRepo
    else
      Repo
    end
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
