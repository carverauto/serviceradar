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
  and are never retried or failed over to another NVR replica; the recorder
  fence stays until its lease lapses. A lost or unreadable NVR answer is
  uncertain, as is a non-200 answer after the end marker. An NVR that refuses
  the unfinished stream (400, 401, 422 or 503 before the end marker) has sealed
  nothing it had open, so that capture returns
  `{:error, {:nvr_ingest_refused, %{status: status, ...}}}` with the worker's
  correlation fields. The worker attempts to release the recorder claim. A
  capture Core itself stops before the worker hands its sender `:eof`, such as
  on a unit with a backwards timestamp, cannot have sent the end marker either,
  so it returns `{:error, {:nvr_ingest_aborted, %{reason: reason, ...}}}` the
  same way; a Core abort after `:eof`, a capture timeout and caller loss stay
  uncertain. Like any other failure, a refused or aborted capture closes the
  relay when this call opened it.

  `:timeout_ms` (default 30,000, at most 300,000) bounds the whole call, and
  `:bounds` sets the worker's frame, byte and media-duration bounds (see
  `ServiceRadarCoreElx.CameraRecording.NVRWorker`). The timeout must cover the
  capture plus relay start-up, the NVR seal and the block's registration: a
  270 s capture, the duration ceiling, needs about 295,000 ms.

  A sealed capture returns `{:ok, receipt}` with `status: :sealed_local`. Its
  `catalog` field is `{:registered, entry_id}` when the worker froze the block's
  descriptor and created its catalog entry. A refusal returns
  `{:unregistered, reason}`. An ambiguous result returns `{:unconfirmed, reason}`.
  The block may or may not be cataloged and the reconciler decides. The
  `release` field is `:released` or
  `{:release_pending_lease_expiry, reason}` when release could not be confirmed.
  The latter permits takeover after the lease expires.
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
  @max_timeout_ms 300_000
  @poll_interval_ms 100
  @interrupt_drain_ms 8_500

  @spec once_source(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def once_source(camera_source_id, stream_profile_id, member, opts \\ []) do
    run_bounded(opts, fn caller, caller_monitor, deadline ->
      actor = resolve_actor(opts)

      open_opts =
        opts
        |> Keyword.take([:control_gateway_resolver, :dispatch_open])
        |> Keyword.merge(actor: actor, return_origin?: true)

      with {:ok, source_id} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
           {:ok, profile_id} <- cast_uuid(stream_profile_id, :invalid_stream_profile_id),
           {:ok, _target} <- NVRTargetConfig.resolve(member, opts),
           true <- RecordingSupervisor.enabled?() || {:error, :recording_disabled},
           {:ok, {origin, requested}} <- RelaySessionManager.request_open(source_id, profile_id, open_opts) do
        capture_requested_session({origin, requested}, member, actor, {caller, caller_monitor}, deadline, opts)
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
      when is_binary(relay_session_id) and is_binary(member) and is_pid(remote_caller) and
             timeout_ms in 1..@max_timeout_ms and is_list(worker_opts) do
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
               caller: remote_caller,
               deadline: deadline,
               bounds: Keyword.get(worker_opts, :bounds, %{}),
               inbox_opts: Keyword.get(worker_opts, :inbox_opts, []),
               notify: self()
             ) do
        await_worker(worker, %{
          caller_monitor: caller_monitor,
          deadline: deadline,
          exit_wait_ms: exit_wait_ms(worker_opts)
        })
      end
    after
      Process.demonitor(caller_monitor, [:flush])
    end
  end

  def capture_on_host(_relay_session_id, _member, _remote_caller, timeout_ms, _worker_opts)
      when timeout_ms not in 1..@max_timeout_ms, do: {:error, :invalid_capture_timeout}

  defp capture_requested_session({origin, session}, member, actor, {_caller, caller_monitor} = watch, deadline, opts) do
    case await_active_relay(session.id, actor, caller_monitor, deadline) do
      {:ok, active_relay} ->
        case await_relay_host(active_relay.id, active_relay.media_ingest_id, caller_monitor, deadline) do
          {:ok, host_node} ->
            host_node
            |> dispatch_to_host(active_relay.id, member, watch, deadline, opts)
            |> close_on_failure(active_relay.id, origin, actor)

          {:error, _reason} = error ->
            close_on_failure(error, active_relay.id, origin, actor)
        end

      {:error, _reason} = error ->
        close_on_failure(error, session.id, origin, actor)
    end
  end

  # A definite failure, including an NVR refusal or a Core abort before the end
  # marker, closes a relay this call opened. An uncertain capture leaves it with
  # its recorder fence.
  defp close_on_failure({:ok, _receipt} = ok, _relay_id, _origin, _actor), do: ok
  defp close_on_failure({:error, {:nvr_ingest_uncertain, _}} = uncertain, _relay_id, _origin, _actor), do: uncertain

  defp close_on_failure({:error, _reason} = error, relay_id, origin, actor) do
    maybe_close_opened_relay(relay_id, origin, actor)
    error
  end

  defp dispatch_to_host(host_node, relay_id, member, {caller, caller_monitor}, deadline, opts) do
    worker_opts = Keyword.take(opts, [:bounds, :inbox_opts, :config_file, :token_file, :exit_wait_ms])
    timeout_ms = max(1, remaining(deadline))

    with :ok <- check_caller(caller_monitor, deadline) do
      send(
        caller,
        {:nvr_capture_dispatched, self(), %{relay_session_id: relay_id, member: member, host_node: host_node}}
      )

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
      timeout_ms + @interrupt_drain_ms + 3_000
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

  defp exit_wait_ms(worker_opts) do
    case Keyword.get(worker_opts, :exit_wait_ms) do
      ms when is_integer(ms) and ms in 1..@interrupt_drain_ms -> ms
      _ -> @interrupt_drain_ms
    end
  end

  defp await_worker(worker, watch) do
    worker_monitor = Process.monitor(worker)
    await_worker_loop(worker, worker_monitor, watch, nil)
  end

  defp await_worker_loop(worker, worker_monitor, %{caller_monitor: caller_monitor} = watch, started_info) do
    receive do
      {:camera_nvr_capture, ^worker, {:attached, _info}} ->
        await_worker_loop(worker, worker_monitor, watch, started_info)

      {:camera_nvr_capture, ^worker, {:started, info}} ->
        await_worker_loop(worker, worker_monitor, watch, info)

      {:camera_nvr_capture, ^worker, {tag, _payload} = event} when tag in [:completed, :uncertain, :failed] ->
        await_worker_exit(worker, worker_monitor, started_info, terminal_result(event), now() + watch.exit_wait_ms)

      {:DOWN, ^caller_monitor, :process, _pid, _reason} ->
        interrupt_worker(worker, worker_monitor, started_info, :capture_cancelled)

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        cancelled_or_uncertain(started_info, {:worker_exited, reason})
    after
      remaining(watch.deadline) ->
        interrupt_worker(worker, worker_monitor, started_info, :capture_timeout)
    end
  end

  defp interrupt_worker(worker, worker_monitor, started_info, reason) do
    GenServer.cast(worker, {:interrupt, reason})
    await_interrupted_worker(worker, worker_monitor, started_info, reason, now() + @interrupt_drain_ms)
  end

  defp await_interrupted_worker(worker, worker_monitor, started_info, reason, drain_deadline) do
    receive do
      {:camera_nvr_capture, ^worker, {:started, info}} ->
        await_interrupted_worker(worker, worker_monitor, info, reason, drain_deadline)

      {:camera_nvr_capture, ^worker, {tag, _payload} = event} when tag in [:completed, :uncertain, :failed] ->
        await_worker_exit(worker, worker_monitor, started_info, terminal_result(event), drain_deadline)

      {:DOWN, ^worker_monitor, :process, ^worker, _exit_reason} ->
        cancelled_or_uncertain(started_info, reason)
    after
      remaining(drain_deadline) ->
        abandon_worker(worker, worker_monitor, started_info, reason)
    end
  end

  defp await_worker_exit(worker, worker_monitor, started_info, result, drain_deadline) do
    receive do
      {:DOWN, ^worker_monitor, :process, ^worker, _exit_reason} -> result
    after
      remaining(drain_deadline) -> unterminated_result(worker, worker_monitor, started_info, result)
    end
  end

  defp unterminated_result(_worker, worker_monitor, _started_info, {:ok, _receipt} = result) do
    Process.demonitor(worker_monitor, [:flush])
    result
  end

  defp unterminated_result(_worker, worker_monitor, nil, {:error, _reason} = result) do
    Process.demonitor(worker_monitor, [:flush])
    result
  end

  defp unterminated_result(worker, worker_monitor, started_info, _result),
    do: abandon_worker(worker, worker_monitor, started_info, :worker_terminate_timeout)

  defp abandon_worker(worker, worker_monitor, nil, reason) do
    Process.exit(worker, :shutdown)
    Process.demonitor(worker_monitor, [:flush])
    cancelled_or_uncertain(nil, reason)
  end

  defp abandon_worker(worker, worker_monitor, started_info, reason) when is_map(started_info) do
    Process.exit(worker, :shutdown)
    Process.demonitor(worker_monitor, [:flush])

    {:error, {:nvr_ingest_uncertain, Map.merge(started_info, %{reason: reason, worker_unterminated: true})}}
  end

  defp terminal_result({:completed, receipt}), do: {:ok, receipt}
  defp terminal_result({:uncertain, details}), do: {:error, {:nvr_ingest_uncertain, details}}
  defp terminal_result({:failed, %{reason: reason}}), do: {:error, reason}

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

  defp maybe_close_opened_relay(_relay_id, :reuse, _actor), do: :ok

  defp maybe_close_opened_relay(relay_id, :new, actor) do
    _ =
      RelaySessionManager.request_close(relay_id,
        reason: "nvr capture failed",
        actor: actor
      )

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp run_bounded(opts, fun) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    if timeout_ms in 1..@max_timeout_ms do
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
        {:ok, timer} = :timer.kill_after(remaining(deadline) + @interrupt_drain_ms + 6_000, self())
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
      await_bounded_result(pid, monitor, request, deadline, nil)
    after
      Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_bounded_result(pid, monitor, request, deadline, dispatched_info) do
    receive do
      {:nvr_capture_dispatched, ^pid, info} ->
        await_bounded_result(pid, monitor, request, deadline, info)

      {^request, result} ->
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        unfinished_result(dispatched_info, deadline)
    after
      remaining(deadline) + @interrupt_drain_ms + 8_000 ->
        unfinished_result(dispatched_info, deadline)
    end
  end

  defp unfinished_result(nil, deadline) do
    {:error, if(remaining(deadline) > 0, do: :capture_unavailable, else: :capture_timeout)}
  end

  defp unfinished_result(dispatched_info, _deadline) do
    {:error, {:nvr_ingest_uncertain, Map.put(dispatched_info, :reason, :capture_timeout)}}
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
