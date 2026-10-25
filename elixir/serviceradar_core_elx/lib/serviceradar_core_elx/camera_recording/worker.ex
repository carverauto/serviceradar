defmodule ServiceRadarCoreElx.CameraRecording.Worker do
  @moduledoc """
  Owns one bounded local recording block under an independent consumer lease.

  Start with a fenced `:owner`, its `:media_ingest_id` and an existing private
  `:spool_root` provisioned explicitly with `Storage.initialize/2`. The deployment
  must configure `:camera_recording_storage_id` as that storage lifetime UUID.
  Startup only verifies the marker; it never creates or repairs one. It resolves
  the existing managed pipeline, then claims exclusive recording rights with a
  fresh token, acquires its recorder lease and attaches to that pipeline.
  The worker owns Packaging/Spool. Its clock maps H264 90 kHz media
  ticks to an explicit recorder epoch; capture UTC remains unknown. Restarting
  recording never asserts clock continuity through an unobserved interval.

  No media or filesystem work runs in the global relay manager. Lease receipts
  establish a conservative monotonic deadline using the request's start time.
  Every storage operation is checked before and after it. A write completing
  after expiry is never published as a receipt. Those local bytes stay on disk
  and grant no upload authority. Local durability is not an archive acknowledgement.

  This first worker stops at one block's finite capacity. It neither rotates nor
  deletes recordings. A codec/clock/sequence reset stops the recorder and requires
  a new epoch; it never silently joins incompatible streams.

  Administrative stop is discovered during lease renewal. The sole producer
  detaches this recorder and places its ordered end marker without ending live
  delivery. Draining uses the existing lease deadline and normal sealing path;
  it grants no extra time to finish or permission to start another block.

  Teardown attempts consumer release and captured-relay idle close for at most
  one second of external work. This is separate from sealing and never upgrades
  a failed media outcome. Lease expiry/reaping remains the fallback after timeout,
  task start failure, or forced process termination.
  """
  use GenServer, restart: :temporary

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingDescriptor
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadarCoreElx.CameraRecording.Inbox
  alias ServiceRadarCoreElx.CameraRecording.Packaging
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.CameraRecording.Storage
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  @lease_ms 30_000

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    name = {:via, Registry, {ServiceRadarCoreElx.CameraRecording.Registry, {owner.id, owner.epoch}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Internal progress only; a node-local snapshot does not authorize playback."
  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    media_ingest_id = Keyword.fetch!(opts, :media_ingest_id)

    with true <- ServiceRadarCoreElx.CameraRecording.Supervisor.enabled?() || {:error, :recording_disabled},
         {:ok, storage} <-
           Storage.open(
             Keyword.fetch!(opts, :spool_root),
             Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)
           ),
         {:ok, pipeline} <- PipelineManager.recording_pipeline(owner.relay_session_id, media_ingest_id) do
      state = %{
        owner: owner,
        media_ingest_id: media_ingest_id,
        claim_token: Ecto.UUID.generate(),
        block: nil,
        init_format: nil,
        pipeline: pipeline,
        monitor: Process.monitor(pipeline),
        storage: storage,
        notify: Keyword.get(opts, :notify),
        inbox_opts: Keyword.get(opts, :inbox, []),
        spool_limits: Keyword.get(opts, :spool_limits, %{}),
        actor: SystemActor.system(:camera_recording),
        claim: nil,
        inbox: nil,
        packager: nil,
        spool: nil,
        timer: nil,
        drain_reason: nil,
        last_sequence: nil,
        terminal: nil,
        seal_error: nil
      }

      {:ok, state, {:continue, :acquire}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:acquire, state) do
    request_start = System.monotonic_time(:millisecond)

    with {:ok, owner} <- IngestOwnership.with_current_owner(state.owner, &{:ok, &1}, actor: state.actor),
         true <- is_binary(owner.relay_session_id) || {:error, :relay_unbound},
         :ok <- Storage.verify(state.storage),
         {:ok, claim} <-
           RecorderOwnership.acquire(owner, state.claim_token, state.media_ingest_id, state.storage.id, @lease_ms,
             actor: state.actor
           ) do
      initialize(%{state | owner: owner, claim: claim}, deadline(request_start, claim))
    else
      {:error, reason} -> stop(state, reason)
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    result = if state.inbox, do: usable(state), else: {:error, :initializing}

    case result do
      :ok -> {:reply, {:ok, %{last_sequence: state.last_sequence, snapshot: snapshot(state)}}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:recording_media, id, unit}, %{inbox: %{id: id}} = state) do
    with :ok <- Inbox.usable(state.inbox),
         :ok <- continuous(state.last_sequence, unit.sequence),
         {:ok, events} <- Packaging.push(state.packager, unit),
         {:ok, next} <- persist(events, state),
         :ok <- Inbox.release(state.inbox, byte_size(unit.payload)) do
      {:noreply, %{next | last_sequence: unit.sequence}}
    else
      {:error, reason} -> stop(state, reason)
    end
  end

  def handle_info({:recording_end, id}, %{inbox: %{id: id}} = state) do
    with :ok <- Inbox.usable(state.inbox),
         {:ok, events} <- Packaging.finish(state.packager),
         {:ok, state} <- persist(events, state),
         {:ok, state} <- seal(state) do
      stop(state, state.drain_reason || :completed)
    else
      {:error, reason} -> stop(state, reason)
    end
  end

  def handle_info({:recording_rejected, id, reason}, %{inbox: %{id: id}} = state), do: stop(state, reason)
  def handle_info({Packaging, pid, {:error, reason}}, %{packager: pid} = state), do: stop(state, reason)
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state), do: stop(state, :ingest_stopped)

  def handle_info(:renew_lease, %{drain_reason: reason} = state) when not is_nil(reason), do: {:noreply, state}

  def handle_info(:renew_lease, state) do
    request_start = System.monotonic_time(:millisecond)

    with :ok <- usable(state),
         {:ok, claim} <- RecorderOwnership.renew(state.owner, state.claim, @lease_ms, actor: state.actor),
         :ok <- Inbox.renew(state.inbox, deadline(request_start, claim)) do
      {:noreply, schedule_renewal(%{state | claim: claim, timer: nil})}
    else
      {:error, :recording_stopped} -> drain(state)
      {:error, reason} -> stop(state, reason)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.inbox, do: Inbox.cancel(state.inbox)
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.packager, do: Packaging.stop(state.packager)
    release_consumer(state)
    :ok
  end

  defp initialize(state, deadline_ms) do
    case Inbox.new(state.pipeline, state.owner.relay_session_id, state.media_ingest_id, deadline_ms, state.inbox_opts) do
      {:ok, inbox} ->
        state = %{state | inbox: inbox}

        clock = %{
          clock_epoch: "#{state.owner.relay_session_id}:#{state.claim.recorder_epoch}",
          timebase: 90_000,
          dts_source: :pts_no_reordering,
          utc_mapping: :unknown
        }

        retained_clock = %{
          "clock_epoch" => clock.clock_epoch,
          "timebase" => clock.timebase,
          "dts_source" => "pts_no_reordering",
          "utc_mapping" => "unknown"
        }

        with :ok <- Inbox.usable(inbox),
             :ok <- Storage.verify(state.storage),
             {:ok, block} <- RecorderOwnership.reserve_block(state.owner, state.claim, retained_clock, actor: state.actor),
             {:ok, packager} <- Packaging.start(clock: clock, wait_for_keyframe?: true) do
          attach(%{state | packager: packager, block: block})
        else
          {:error, reason} -> stop(state, reason)
        end

      {:error, reason} ->
        stop(state, reason)
    end
  end

  defp attach(state) do
    with :ok <- Storage.verify(state.storage),
         :ok <- Membrane.Pipeline.call(state.pipeline, {:attach_recorder, state.inbox}, 5_000) do
      notify(state, :ready)
      {:noreply, schedule_renewal(state)}
    else
      {:error, reason} ->
        stop(state, reason)
    end
  catch
    :exit, _reason -> stop(state, :ingest_stopped)
  end

  defp drain(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timeout = min(5_000, max(1, Inbox.remaining_ms(state.inbox)))

    with :ok <- usable(state),
         :ok <- Membrane.Pipeline.call(state.pipeline, {:drain_recorder, state.inbox.id}, timeout) do
      {:noreply, %{state | timer: nil, drain_reason: :recording_stopped}}
    else
      {:error, reason} -> stop(state, reason)
    end
  catch
    :exit, _reason -> stop(state, :recording_drain_failed)
  end

  defp persist(events, state) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      with :ok <- Inbox.usable(state.inbox),
           {:ok, next} <- store(event, state),
           :ok <- Inbox.usable(state.inbox) do
        {:cont, {:ok, next}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp store({:init, init}, state) do
    identity = state.block |> RecordingBlock.identity() |> Map.put("clock", init.clock)

    with {:ok, spool} <- Spool.create(state.storage, identity, init.payload, state.spool_limits) do
      {:ok, %{state | spool: spool, init_format: Map.take(init, [:sha256, :timescale, :codecs])}}
    end
  end

  defp store({:fragment, fragment}, state) do
    case Spool.append(state.spool, fragment.payload, fragment) do
      {:ok, spool, _entry} -> {:ok, %{state | spool: spool}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seal(%{spool: nil}), do: {:error, :no_recorded_media}

  defp seal(state) do
    with :ok <- usable(state),
         {:ok, spool} <- Spool.seal(state.spool),
         :ok <- usable(state),
         {:ok, descriptor} <- RecordingDescriptor.from_snapshot(Spool.snapshot(spool), state.init_format),
         {:ok, block} <- RecordingBlocks.freeze(state.owner, state.claim, state.block, descriptor, actor: state.actor),
         :ok <- usable(state) do
      {:ok, %{state | spool: spool, block: block}}
    end
  end

  defp stop(state, reason) do
    state = seal_committed_tail(state, reason)
    committed = if state.inbox && usable(state) == :ok, do: snapshot(state)
    if state.inbox, do: Inbox.cancel(state.inbox)
    notify(state, {:stopped, %{reason: reason, snapshot: committed, seal_error: state.seal_error}})
    {:stop, :normal, %{state | terminal: reason}}
  end

  defp seal_committed_tail(%{spool: %{high_water: bytes}} = state, reason)
       when bytes > 0 and reason in [:block_full, :insufficient_tail_samples] do
    case seal(state) do
      {:ok, sealed} -> sealed
      {:error, error} -> %{state | seal_error: error}
    end
  end

  defp seal_committed_tail(state, _reason), do: state

  defp release_consumer(%{claim: nil}), do: :ok

  defp release_consumer(state) do
    owner = state.owner
    claim = state.claim
    actor = state.actor

    # This one linked task belongs only to the stopping worker (which traps
    # exits). The worker cap bounds concurrency; a Task.Supervisor start call
    # itself waits indefinitely in Elixir 1.19.1, so it cannot bound teardown.
    task = Task.async(fn -> release_and_close(owner, claim, actor) end)

    try do
      case Task.yield(task, 1_000) do
        {:ok, result} -> result
        _ -> {:error, :cleanup_incomplete}
      end
    after
      Task.shutdown(task, :brutal_kill)
    end
  catch
    _kind, _reason -> {:error, :cleanup_start_failed}
  end

  defp release_and_close(owner, claim, actor) do
    case RecorderOwnership.release(owner, claim, actor: actor) do
      {:ok, :released} ->
        RelaySessionManager.request_close(owner.relay_session_id,
          reason: "recorder detached",
          actor: actor
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp usable(state) do
    with :ok <- Inbox.usable(state.inbox), do: Storage.verify(state.storage)
  end

  defp snapshot(%{spool: nil}), do: nil
  defp snapshot(state), do: Spool.snapshot(state.spool)
  defp notify(%{notify: pid}, event) when is_pid(pid), do: send(pid, {:camera_recording, self(), event})
  defp notify(_state, _event), do: :ok
  defp continuous(nil, _sequence), do: :ok
  defp continuous(previous, sequence) when sequence == previous + 1, do: :ok
  defp continuous(_previous, _sequence), do: {:error, :media_sequence_discontinuity}

  defp deadline(request_start, claim),
    do: request_start + max(0, DateTime.diff(claim.lease_expires_at, claim.database_now, :millisecond))

  defp schedule_renewal(state) do
    delay = min(5_000, max(1, div(Inbox.remaining_ms(state.inbox), 2)))
    %{state | timer: Process.send_after(self(), :renew_lease, delay)}
  end
end
