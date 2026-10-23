defmodule ServiceRadarCoreElx.CameraRecording.Inbox do
  @moduledoc """
  Node-local recording admission, checked before any media enters a mailbox.

  One relay pipeline is the sole producer. A single atomic word reserves byte
  and sample credits together; the worker returns them after packaging and disk
  work. Closing cancels all outstanding credits once. No producer waits for the
  worker. End-of-stream comes from the same producer, after its admitted media.
  That ordered end permits draining after the producer exits; an open inbox
  becomes unusable when its producer dies.
  """

  @byte_base 4_294_967_296
  @closed -1
  @draining -2
  @reasons %{queue_full: -3, lease_expired: -4, unsupported_media: -5, admission_contention: -6}
  @max_access_unit_bytes 1_048_576
  @max_ticks 9_223_372_036_854_775_807

  @enforce_keys [:worker, :producer, :relay_session_id, :id, :counters, :max_bytes, :max_samples]
  defstruct @enforce_keys

  def new(producer, relay_session_id, deadline_ms, opts \\ [])
      when is_pid(producer) and node(producer) == node() and is_integer(deadline_ms) do
    max_bytes = Keyword.get(opts, :max_bytes, 8_388_608)
    max_samples = Keyword.get(opts, :max_samples, 8)

    if max_bytes in 1..16_777_216 and max_samples in 1..128 do
      counters = :atomics.new(2, signed: true)
      :ok = :atomics.put(counters, 2, deadline_ms)

      {:ok,
       %__MODULE__{
         worker: self(),
         producer: producer,
         relay_session_id: relay_session_id,
         id: make_ref(),
         counters: counters,
         max_bytes: max_bytes,
         max_samples: max_samples
       }}
    else
      {:error, :invalid_inbox_limits}
    end
  end

  def offer(%__MODULE__{producer: producer} = inbox, chunk) when producer == self() do
    with :ok <- usable(inbox),
         {:ok, unit} <- access_unit(chunk),
         :ok <- reserve(inbox, byte_size(unit.payload), 129) do
      # Avoid retaining a larger decoded transport binary through a small sub-binary.
      send(inbox.worker, {:recording_media, inbox.id, %{unit | payload: :binary.copy(unit.payload)}})
      :ok
    else
      {:error, reason} = error ->
        fail(inbox, reason)
        error
    end
  end

  def offer(_inbox, _chunk), do: {:error, :not_recording_producer}

  def finish(%__MODULE__{producer: producer} = inbox) when producer == self() do
    if transition(inbox, @draining) do
      send(inbox.worker, {:recording_end, inbox.id})
    end

    :ok
  end

  def finish(_inbox), do: {:error, :not_recording_producer}

  def cancel(%__MODULE__{} = inbox) do
    :atomics.exchange(inbox.counters, 1, @closed)
    :ok
  end

  def release(%__MODULE__{worker: worker} = inbox, bytes) when worker == self(), do: release(inbox, bytes, 129)

  def renew(%__MODULE__{worker: worker} = inbox, deadline_ms) when worker == self() do
    :ok = :atomics.put(inbox.counters, 2, deadline_ms)
    usable(inbox)
  end

  def usable(%__MODULE__{} = inbox) do
    status = :atomics.get(inbox.counters, 1)

    cond do
      status < @draining -> {:error, reason(status)}
      status == @closed -> {:error, :recording_closed}
      System.monotonic_time(:millisecond) >= :atomics.get(inbox.counters, 2) -> {:error, :lease_expired}
      not Process.alive?(inbox.worker) -> {:error, :recording_closed}
      status >= 0 and not Process.alive?(inbox.producer) -> {:error, :ingest_stopped}
      true -> :ok
    end
  end

  def remaining_ms(%__MODULE__{} = inbox),
    do: max(0, :atomics.get(inbox.counters, 2) - System.monotonic_time(:millisecond))

  defp access_unit(%{codec: "h264", payload_format: "annexb", payload: bytes, pts: pts, dts: dts, sequence: seq})
       when is_binary(bytes) and byte_size(bytes) in 1..@max_access_unit_bytes and pts in 0..@max_ticks and
              dts in 0..@max_ticks and seq in 0..18_446_744_073_709_551_615,
       do: {:ok, %{payload: bytes, pts: pts, dts: dts, sequence: seq}}

  defp access_unit(_chunk), do: {:error, :unsupported_media}

  defp reserve(_inbox, _bytes, 0), do: {:error, :admission_contention}

  defp reserve(inbox, bytes, attempts) do
    current = :atomics.get(inbox.counters, 1)

    cond do
      current < 0 ->
        {:error, :recording_closed}

      div(current, @byte_base) >= inbox.max_samples or rem(current, @byte_base) + bytes > inbox.max_bytes ->
        {:error, :queue_full}

      :atomics.compare_exchange(inbox.counters, 1, current, current + @byte_base + bytes) == :ok ->
        :ok

      true ->
        reserve(inbox, bytes, attempts - 1)
    end
  end

  defp release(inbox, _bytes, 0), do: fail(inbox, :admission_contention)

  defp release(inbox, bytes, attempts) do
    current = :atomics.get(inbox.counters, 1)

    cond do
      current < 0 -> :ok
      :atomics.compare_exchange(inbox.counters, 1, current, current - @byte_base - bytes) == :ok -> :ok
      true -> release(inbox, bytes, attempts - 1)
    end
  end

  defp fail(inbox, reason) do
    if transition(inbox, Map.get(@reasons, reason, @closed)) do
      send(inbox.worker, {:recording_rejected, inbox.id, reason})
    end

    :ok
  end

  defp transition(inbox, desired), do: transition(inbox, desired, 129)

  defp transition(inbox, _desired, 0) do
    # A bounded retry exhaustion can only force a terminal fault, never replace
    # an existing terminal state with the still-readable draining state.
    if :atomics.exchange(inbox.counters, 1, @closed) >= 0 do
      send(inbox.worker, {:recording_rejected, inbox.id, :admission_contention})
    end

    false
  end

  defp transition(inbox, desired, attempts) do
    current = :atomics.get(inbox.counters, 1)

    cond do
      current < 0 -> false
      :atomics.compare_exchange(inbox.counters, 1, current, desired) == :ok -> true
      true -> transition(inbox, desired, attempts - 1)
    end
  end

  defp reason(status),
    do: Enum.find_value(@reasons, :recording_closed, fn {reason, code} -> if code == status, do: reason end)
end
