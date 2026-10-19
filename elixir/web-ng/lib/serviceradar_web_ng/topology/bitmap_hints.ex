defmodule ServiceRadarWebNG.Topology.BitmapHints do
  @moduledoc """
  FIFO identity hints with bounded payload and conservative retained-memory charges.

  Queued identities coalesce. A drained batch stays charged until resolution
  succeeds; another invalidation of an in-flight identity queues a new read.
  Copies own their bytes so a short sub-binary cannot retain an ingestion frame.
  Charges cover live queue/set/batch terms, not mailbox, GC or worker RSS.
  """
  @payload_limit 524_288
  # 3.5 MiB fits alongside the index, two mappings and prefix catalogs inside
  # the 200 MB steady component budget.
  @memory_limit 3_670_016
  # Room for the FIFO cell, age tuple, HAMT/set entries and binary references,
  # including the transient queue reversal. The owned payload is charged apart.
  @entry_bytes 256

  defstruct queue: {[], []}, seen: MapSet.new(), active: [], payload_bytes: 0, retained_bytes: 0

  def new, do: %__MODULE__{}
  def count(hints), do: MapSet.size(hints.seen) + length(hints.active)
  def limit(:bytes), do: @payload_limit
  def limit(:memory), do: @memory_limit

  def put(hints, ids, at) do
    Enum.reduce(ids, {hints, %{bytes: 0, memory: 0}}, fn id, {hints, overflow} ->
      cond do
        not is_binary(id) or id == "" or MapSet.member?(hints.seen, id) ->
          {hints, overflow}

        hints.payload_bytes + byte_size(id) > @payload_limit ->
          {hints, Map.update!(overflow, :bytes, &(&1 + 1))}

        hints.retained_bytes + charge(id) > @memory_limit ->
          {hints, Map.update!(overflow, :memory, &(&1 + 1))}

        true ->
          id = :binary.copy(id)

          {%{
             hints
             | queue: :queue.in({id, at}, hints.queue),
               seen: MapSet.put(hints.seen, id),
               payload_bytes: hints.payload_bytes + byte_size(id),
               retained_bytes: hints.retained_bytes + charge(id)
           }, overflow}
      end
    end)
  end

  def take(%{active: []} = hints, limit) when limit in 1..500 do
    {items, queue} = drain(hints.queue, limit, [])
    ids = Enum.map(items, &elem(&1, 0))
    {ids, %{hints | queue: queue, seen: MapSet.difference(hints.seen, MapSet.new(ids)), active: items}}
  end

  def take(hints, limit) when limit in 1..500, do: {Enum.map(hints.active, &elem(&1, 0)), hints}

  def complete(hints) do
    Enum.reduce(hints.active, %{hints | active: []}, fn {id, _at}, hints ->
      %{hints | payload_bytes: hints.payload_bytes - byte_size(id), retained_bytes: hints.retained_bytes - charge(id)}
    end)
  end

  def age_ms(hints, now) do
    queued =
      case :queue.peek(hints.queue) do
        {:value, {_id, at}} -> at
        :empty -> now
      end

    active =
      case hints.active do
        [{_id, at} | _] -> at
        [] -> now
      end

    now - min(queued, active)
  end

  defp drain(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp drain(queue, remaining, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> drain(rest, remaining - 1, [item | acc])
      {:empty, rest} -> {Enum.reverse(acc), rest}
    end
  end

  defp charge(id), do: @entry_bytes + div(byte_size(id) + 7, 8) * 8
end
