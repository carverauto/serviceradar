defmodule ServiceRadarCoreElx.CameraRecording.NVRCapture do
  @moduledoc """
  Coordinates one bounded relay-to-NVR recording from an authorized camera source.

  Supports capturing either from an active `relay_session_id` (`once_relay/3`) or
  from an existing `(camera_source_id, stream_profile_id)` (`once_source/4`),
  reusing an active shared relay when present or opening the shared relay once
  through `RelaySessionManager.request_open/3`.

  Media production runs on the `core-elx` node that hosts the relay pipeline
  (`ServiceRadar.Camera.RelayHosts`), so camera media never traverses ERTS
  distribution or NATS/JetStream. Uncertain transport or RPC outcomes after
  streaming begins are returned as `{:error, {:nvr_ingest_uncertain, details}}`
  and are never retried or failed over to another NVR replica.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelayHosts
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadarCoreElx.CameraRecording.NVRTargetConfig
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  @default_timeout_ms 30_000
  @poll_interval_ms 100
  @result_grace_ms 2_000

  @spec once_source(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def once_source(camera_source_id, stream_profile_id, member, opts \\ []) do
    run_bounded(opts, fn caller, caller_monitor, deadline ->
      actor = resolve_actor(opts)
      open_opts = opts |> Keyword.take([:control_gateway_resolver, :dispatch_open]) |> Keyword.put(:actor, actor)

      with {:ok, source_id} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
           {:ok, profile_id} <- cast_uuid(stream_profile_id, :invalid_stream_profile_id),
           {:ok, _target} <- NVRTargetConfig.resolve(member, opts),
           {:ok, requested} <- RelaySessionManager.request_open(source_id, profile_id, open_opts) do
        capture_requested_session(requested, member, actor, {caller, caller_monitor}, deadline, opts)
      end
    end)
  end

  @spec once_relay(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def once_relay(relay_session_id, member, opts \\ []) do
    run_bounded(opts, fn caller, caller_monitor, deadline ->
      actor = resolve_actor(opts)

      with {:ok, relay_id} <- cast_uuid(relay_session_id, :invalid_relay_id),
           {:ok, _target} <- NVRTargetConfig.resolve(member, opts),
           {:ok, relay} <- fetch_active_relay(relay_id, actor),
           {:ok, host_node} <- await_relay_host(relay.id, relay.media_ingest_id, caller_monitor, deadline) do
        dispatch_to_host(host_node, relay.id, member, {caller, caller_monitor}, deadline, opts)
      end
    end)
  end

  @doc false
  def capture_on_host(relay_session_id, member, remote_caller, timeout_ms, worker_opts)
      when is_binary(relay_session_id) and is_binary(member) and is_pid(remote_caller) and is_integer(timeout_ms) and
             timeout_ms > 0 and is_list(worker_opts) do
    deadline = now() + timeout_ms
    caller_monitor = Process.monitor(remote_caller)

    try do
      actor = SystemActor.system(:camera_recording)

      with true <- RecordingSupervisor.enabled?() || {:error, :recording_disabled},
           {:ok, target} <- NVRTargetConfig.resolve(member, worker_opts),
           {:ok, relay} <- fetch_active_relay(relay_session_id, actor),
           {:ok, owner} <- IngestOwnership.for_relay(relay.id, actor: actor),
           :ok <- check_caller(caller_monitor, deadline),
           {:ok, worker} <-
             RecordingSupervisor.start_nvr_recorder(
               owner: owner,
               media_ingest_id: relay.media_ingest_id,
               member: target.member,
               storage_id: target.storage_id,
               client_config: target.client_config,
               caller: self(),
               deadline: deadline,
               bounds: Keyword.get(worker_opts, :bounds, %{}),
               inbox_opts: Keyword.get(worker_opts, :inbox_opts, []),
               notify: self()
             ) do
        await_worker(worker, caller_monitor, deadline)
      end
    after
      Process.demonitor(caller_monitor, [:flush])
    end
  end

  defp capture_requested_session(session, member, actor, {_caller, caller_monitor} = watch, deadline, opts) do
    case await_active_relay(session.id, actor, caller_monitor, deadline) do
      {:ok, active_relay} ->
        case await_relay_host(active_relay.id, active_relay.media_ingest_id, caller_monitor, deadline) do
          {:ok, host_node} ->
            dispatch_to_host(host_node, active_relay.id, member, watch, deadline, opts)

          {:error, _reason} = error ->
            maybe_close_unstarted_relay(active_relay.id, actor)
            error
        end

      {:error, _reason} = error ->
        maybe_close_unstarted_relay(session.id, actor)
        error
    end
  end

  defp dispatch_to_host(host_node, relay_id, member, {caller, caller_monitor}, deadline, opts) do
    worker_opts = Keyword.take(opts, [:bounds, :inbox_opts, :config_file, :token_file])
    timeout_ms = max(1, remaining(deadline))

    with :ok <- check_caller(caller_monitor, deadline) do
      if host_node == node() do
        capture_on_host(relay_id, member, caller, timeout_ms, worker_opts)
      else
        call_remote_host(host_node, relay_id, member, caller, timeout_ms, worker_opts)
      end
    end
  end

  defp call_remote_host(host_node, relay_id, member, caller, timeout_ms, worker_opts) do
    :erpc.call(
      host_node,
      __MODULE__,
      :capture_on_host,
      [relay_id, member, caller, timeout_ms, worker_opts],
      timeout_ms
    )
  catch
    :error, {:erpc, erpc_reason} ->
      {:error,
       {:nvr_ingest_uncertain,
        %{
          reason: {:erpc, erpc_reason},
          host_node: host_node,
          relay_session_id: relay_id,
          member: member
        }}}
  end

  defp await_worker(worker, caller_monitor, deadline) do
    worker_monitor = Process.monitor(worker)
    await_worker_loop(worker, worker_monitor, caller_monitor, deadline, nil)
  end

  defp await_worker_loop(worker, worker_monitor, caller_monitor, deadline, started_info) do
    receive do
      {:camera_nvr_capture, ^worker, {:attached, _info}} ->
        await_worker_loop(worker, worker_monitor, caller_monitor, deadline, started_info)

      {:camera_nvr_capture, ^worker, {:started, info}} ->
        await_worker_loop(worker, worker_monitor, caller_monitor, deadline, info)

      {:camera_nvr_capture, ^worker, {:completed, receipt}} ->
        Process.demonitor(worker_monitor, [:flush])
        {:ok, receipt}

      {:camera_nvr_capture, ^worker, {:uncertain, details}} ->
        Process.demonitor(worker_monitor, [:flush])
        {:error, {:nvr_ingest_uncertain, details}}

      {:camera_nvr_capture, ^worker, {:failed, %{reason: reason}}} ->
        Process.demonitor(worker_monitor, [:flush])
        {:error, reason}

      {:DOWN, ^caller_monitor, :process, _pid, _reason} ->
        GenServer.cast(worker, {:interrupt, :capture_cancelled})
        Process.demonitor(worker_monitor, [:flush])
        cancelled_or_uncertain(started_info, :capture_cancelled)

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        cancelled_or_uncertain(started_info, {:worker_exited, reason})
    after
      remaining(deadline) ->
        GenServer.cast(worker, {:interrupt, :capture_timeout})
        Process.demonitor(worker_monitor, [:flush])
        cancelled_or_uncertain(started_info, :capture_timeout)
    end
  end

  defp cancelled_or_uncertain(nil, :capture_cancelled), do: {:error, :capture_cancelled}
  defp cancelled_or_uncertain(nil, :capture_timeout), do: {:error, :capture_timeout}
  defp cancelled_or_uncertain(nil, _other), do: {:error, :capture_unavailable}

  defp cancelled_or_uncertain(started_info, reason) do
    {:error, {:nvr_ingest_uncertain, Map.put(started_info, :reason, reason)}}
  end

  defp fetch_active_relay(relay_id, actor) do
    case RelaySession.get_by_id(relay_id, actor: actor) do
      {:ok, %RelaySession{status: :active, media_ingest_id: ingest_id} = relay}
      when is_binary(ingest_id) and ingest_id != "" ->
        {:ok, relay}

      {:ok, %RelaySession{}} ->
        {:error, :relay_not_active}

      _ ->
        {:error, :relay_not_found}
    end
  end

  defp resolve_actor(opts) do
    Keyword.get_lazy(opts, :actor, fn -> SystemActor.system(:camera_recording) end)
  end

  defp await_active_relay(relay_id, actor, caller_monitor, deadline) do
    with :ok <- check_caller(caller_monitor, deadline) do
      poll_active_relay(relay_id, actor, caller_monitor, deadline)
    end
  end

  defp poll_active_relay(relay_id, actor, caller_monitor, deadline) do
    case RelaySession.get_by_id(relay_id, actor: actor) do
      {:ok, %RelaySession{status: :active, media_ingest_id: ingest_id} = relay}
      when is_binary(ingest_id) and ingest_id != "" ->
        {:ok, relay}

      {:ok, %RelaySession{status: status}} when status in [:requested, :opening] ->
        wait_step(caller_monitor, deadline, fn ->
          await_active_relay(relay_id, actor, caller_monitor, deadline)
        end)

      {:ok, %RelaySession{status: status}} ->
        {:error, {:relay_session_terminal, status}}

      _ ->
        {:error, :relay_not_found}
    end
  end

  defp await_relay_host(relay_id, media_ingest_id, caller_monitor, deadline) do
    with :ok <- check_caller(caller_monitor, deadline) do
      poll_relay_host(relay_id, media_ingest_id, caller_monitor, deadline)
    end
  end

  defp poll_relay_host(relay_id, media_ingest_id, caller_monitor, deadline) do
    cond do
      match?({:ok, _pid}, PipelineManager.recording_pipeline(relay_id, media_ingest_id)) ->
        {:ok, node()}

      is_atom(RelayHosts.host_node(relay_id)) and RelayHosts.host_node(relay_id) != nil ->
        {:ok, RelayHosts.host_node(relay_id)}

      Process.whereis(:serviceradar_camera_relay_hosts) != nil ->
        wait_step(caller_monitor, deadline, fn ->
          await_relay_host(relay_id, media_ingest_id, caller_monitor, deadline)
        end)

      true ->
        {:error, :relay_pipeline_not_hosted}
    end
  end

  defp wait_step(caller_monitor, deadline, next_fun) do
    wait_ms = min(@poll_interval_ms, remaining(deadline))

    if wait_ms <= 0 do
      {:error, :capture_timeout}
    else
      receive do
        {:DOWN, ^caller_monitor, :process, _pid, _reason} -> {:error, :capture_cancelled}
      after
        wait_ms -> next_fun.()
      end
    end
  end

  defp maybe_close_unstarted_relay(relay_id, actor) do
    _ =
      RelaySessionManager.request_close(relay_id,
        reason: "nvr capture aborted before recorder start",
        actor: actor
      )

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp run_bounded(opts, fun) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    if is_integer(timeout_ms) and timeout_ms > 0 do
      do_run_bounded(timeout_ms, fun)
    else
      {:error, :invalid_capture_timeout}
    end
  end

  defp do_run_bounded(timeout_ms, fun) do
    deadline = now() + timeout_ms
    caller = self()
    request = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, timer} = :timer.kill_after(remaining(deadline) + @result_grace_ms, self())
        caller_monitor = Process.monitor(caller)

        result =
          try do
            fun.(caller, caller_monitor, deadline)
          after
            :timer.cancel(timer)
          end

        send(caller, {request, result})
      end)

    try do
      receive do
        {^request, result} ->
          result

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          {:error, if(remaining(deadline) > 0, do: :capture_unavailable, else: :capture_timeout)}
      after
        remaining(deadline) + 2 * @result_grace_ms ->
          {:error, :capture_timeout}
      end
    after
      Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp cast_uuid(value, error_tag) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error_tag}
    end
  end

  defp check_caller(caller_monitor, deadline) do
    receive do
      {:DOWN, ^caller_monitor, :process, _pid, _reason} -> {:error, :capture_cancelled}
    after
      0 -> if(remaining(deadline) > 0, do: :ok, else: {:error, :capture_timeout})
    end
  end

  defp remaining(deadline), do: max(0, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end
