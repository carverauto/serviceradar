defmodule ServiceRadarCoreElx.CameraRecording.Capture do
  @moduledoc """
  Captures at most one finite local block from this node's existing camera relay.

  This release-callable administration operation accepts only the relay UUID.
  Boot configuration supplies the opt-in and provisioned spool root. It neither
  opens a relay nor uploads bytes, resumes durable stop, or grants playback.
  Only the worker's committed freeze receipt can return a block UUID.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor

  @timeout_ms 30_000
  @limits %{
    max_init_bytes: 1_048_576,
    max_fragment_bytes: 4_194_304,
    max_block_bytes: 16_777_216,
    max_fragments: 3
  }

  def once(relay_id) do
    deadline = now() + @timeout_ms
    caller = self()
    request = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        # A caller monitor cannot interrupt a blocked lookup or supervisor call.
        {:ok, timer} = :timer.kill_after(remaining(deadline), self())

        caller_monitor = Process.monitor(caller)

        result =
          try do
            capture(relay_id, caller_monitor, deadline)
          after
            :timer.cancel(timer)
          end

        send(caller, {request, result})
      end)

    try do
      receive do
        {^request, result} ->
          if(remaining(deadline) > 0, do: result, else: {:error, :capture_timeout})

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          {:error, if(remaining(deadline) > 0, do: :capture_unavailable, else: :capture_timeout)}
      after
        remaining(deadline) -> {:error, :capture_timeout}
      end
    after
      Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp capture(relay_id, caller_monitor, deadline) do
    opts = [actor: SystemActor.system(:camera_recording)]

    with true <- RecordingSupervisor.enabled?() || {:error, :recording_disabled},
         {:ok, relay_id} <- Ecto.UUID.cast(relay_id),
         root when is_binary(root) <- Application.get_env(:serviceradar_core_elx, :camera_recording_spool_root),
         true <- Path.type(root) == :absolute || {:error, :invalid_recording_spool},
         {:ok, relay} <- RelaySession.get_by_id(relay_id, opts),
         {:ok, owner} <- IngestOwnership.for_relay(relay_id, opts),
         :ok <- current(caller_monitor, deadline),
         {:ok, worker} <-
           RecordingSupervisor.start_recorder(
             owner: owner,
             media_ingest_id: relay.media_ingest_id,
             spool_root: root,
             spool_limits: @limits,
             notify: self(),
             capture: %{owner: self(), deadline: deadline}
           ) do
      monitor = Process.monitor(worker)
      await(worker, monitor, caller_monitor, deadline)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      :error -> {:error, :invalid_relay_id}
      nil -> {:error, :recording_spool_not_configured}
      _ -> {:error, :capture_unavailable}
    end
  end

  defp await(worker, monitor, caller_monitor, deadline) do
    receive do
      {:camera_recording, ^worker, :ready} ->
        await(worker, monitor, caller_monitor, deadline)

      {:camera_recording, ^worker, {:stopped, %{block_id: id, seal_error: nil}}} when is_binary(id) ->
        with :ok <- current(caller_monitor, deadline), do: {:ok, %{block_id: id}}

      {:camera_recording, ^worker, {:stopped, %{seal_error: error}}} when not is_nil(error) ->
        {:error, :capture_seal_failed}

      {:camera_recording, ^worker, {:stopped, %{reason: reason}}} ->
        {:error, reason}

      {:DOWN, ^caller_monitor, :process, _pid, _reason} ->
        {:error, :capture_cancelled}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :capture_unavailable}
    after
      remaining(deadline) -> {:error, :capture_timeout}
    end
  end

  defp current(caller_monitor, deadline) do
    receive do
      {:DOWN, ^caller_monitor, :process, _pid, _reason} -> {:error, :capture_cancelled}
    after
      0 -> if(remaining(deadline) > 0, do: :ok, else: {:error, :capture_timeout})
    end
  end

  defp remaining(deadline), do: max(0, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end
