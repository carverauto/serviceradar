defmodule ServiceRadarNVR.Session do
  @moduledoc false
  use GenServer, restart: :temporary

  alias ServiceRadarNVR.Capacity
  alias ServiceRadarRecording.Inbox
  alias ServiceRadarRecording.Packaging
  alias ServiceRadarRecording.Writer

  def start_link(config, {producer, identity, clock}) do
    with {:ok, key} <- source_key(identity) do
      GenServer.start_link(__MODULE__, {config, producer, identity, clock},
        name: {:via, Registry, {ServiceRadarNVR.Registry, key}}
      )
    end
  end

  @impl true
  def init({%{root: nil}, _producer, _identity, _clock}), do: {:stop, :nvr_storage_not_configured}

  def init({config, producer, identity, clock}) do
    Process.flag(:trap_exit, true)
    deadline = System.monotonic_time(:millisecond) + config.max_duration_ms

    with {:ok, reservation, storage, limits} <- Capacity.reserve(),
         {:ok, inbox} <- Inbox.new(producer, identity.source_id, identity, deadline),
         {:ok, writer} <- Writer.open(storage, identity, clock, limits, wait_for_keyframe?: true) do
      timer = Process.send_after(self(), :deadline, max(0, deadline - System.monotonic_time(:millisecond)))

      {:ok,
       %{
         inbox: inbox,
         writer: writer,
         reservation: reservation,
         monitor: Process.monitor(producer),
         timer: timer,
         last_sequence: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(_message, {caller, _}, %{inbox: %{producer: owner}} = state) when caller != owner,
    do: {:reply, {:error, :not_recording_producer}, state}

  def handle_call(:inbox, _from, state), do: {:reply, state.inbox, state}

  def handle_call(:status, _from, state),
    do:
      {:reply,
       %{
         last_sequence: state.last_sequence,
         block_sequence: state.writer.identity.block_sequence,
         remaining_ms: Inbox.remaining_ms(state.inbox)
       }, state}

  def handle_call(:stop, _from, state) do
    notify(state, {:error, :cancelled})
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:recording_media, id, unit}, %{inbox: %{id: id}} = state) do
    with :ok <- continuous(state.last_sequence, unit.sequence),
         {:ok, writer} <- Writer.push(state.writer, unit, fn -> admitted(state) end, next_block(state)),
         :ok <- Inbox.release(state.inbox, byte_size(unit.payload)) do
      {:noreply, %{state | writer: writer, last_sequence: unit.sequence}}
    else
      {:error, reason} -> finish_error(state, reason)
    end
  end

  def handle_info({:recording_end, id}, %{inbox: %{id: id}} = state) do
    with {:ok, writer} <- Writer.flush(state.writer, fn -> admitted(state) end, next_block(state)),
         {:ok, writer} <- Writer.seal(writer, fn -> admitted(state) end) do
      notify(state, {:ok, %{snapshot: Writer.snapshot(writer), init_format: writer.init_format}})
      {:stop, :normal, %{state | writer: writer}}
    else
      {:error, reason} -> finish_error(state, reason)
    end
  end

  def handle_info({:recording_rejected, id, reason}, %{inbox: %{id: id}} = state), do: finish_error(state, reason)

  def handle_info({Packaging, pid, {:error, reason}}, %{writer: %{packager: pid}} = state),
    do: finish_error(state, reason)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: finish_error(state, :producer_stopped)

  def handle_info(:deadline, state), do: finish_error(state, :lease_expired)

  @impl true
  def terminate(_reason, state) do
    Inbox.cancel(state.inbox)
    Process.cancel_timer(state.timer)
    Writer.close(state.writer)
    :ok
  end

  defp finish_error(state, reason) do
    # Retain provisional bytes for explicit recovery; failure never publishes a receipt.
    notify(state, {:error, reason})
    {:stop, :normal, state}
  end

  defp notify(state, result), do: send(state.inbox.producer, {:nvr_recording, self(), result})

  defp next_block(state) do
    fn snapshot, init_format ->
      send(state.inbox.producer, {:nvr_block_sealed, self(), %{snapshot: snapshot, init_format: init_format}})

      with :ok <- Capacity.next_block(state.reservation),
           :ok <- Inbox.usable(state.inbox) do
        {:ok, %{state.writer.identity | block_sequence: snapshot.identity["block_sequence"] + 1}}
      end
    end
  end

  defp admitted(state) do
    with :ok <- Inbox.usable(state.inbox),
         :ok <- Capacity.check(state.reservation),
         do: Inbox.usable(state.inbox)
  end

  defp continuous(nil, _sequence), do: :ok
  defp continuous(previous, sequence) when sequence == previous + 1, do: :ok
  defp continuous(_, _), do: {:error, :media_sequence_discontinuity}

  defguardp bounded_name(value) when is_binary(value) and byte_size(value) in 1..128

  defp source_key(%{source_id: source, profile: profile, recorder_epoch: epoch, block_sequence: seq} = identity)
       when bounded_name(source) and bounded_name(profile) and is_integer(epoch) and epoch > 0 and is_integer(seq) and
              seq >= 0 and map_size(identity) == 4, do: {:ok, {source, profile}}

  defp source_key(_), do: {:error, :invalid_recording_identity}
end
