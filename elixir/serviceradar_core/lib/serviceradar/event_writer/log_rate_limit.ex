defmodule ServiceRadar.EventWriter.LogRateLimit do
  @moduledoc """
  Admits at most one log line per key per interval, counting the lines it held back.

  For a condition that can fail many batches at once and clears by itself, such as a Dgraph
  leader election failing every edge record projected during it: one line per interval says it
  is happening and how often, instead of one line per batch.

  Each key's state is an `:atomics` array registered in `:persistent_term` the first time the
  key is seen, so keys must come from a small fixed set (batcher names, not record ids).
  """

  @doc """
  `{:log, suppressed}` when a line for `key` may be logged now, with the number of lines held
  back since the last one; `:suppress` otherwise.
  """
  @spec admit(term(), pos_integer()) :: {:log, non_neg_integer()} | :suppress
  def admit(key, interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    state = state(key)
    now_ms = System.os_time(:millisecond)
    last_ms = :atomics.get(state, 1)

    if now_ms - last_ms >= interval_ms and
         :atomics.compare_exchange(state, 1, last_ms, now_ms) == :ok do
      {:log, :atomics.exchange(state, 2, 0)}
    else
      :atomics.add(state, 2, 1)
      :suppress
    end
  end

  # Two processes seeing a new key at once may each register an array; the later one wins and
  # the other's count is lost, which costs at most one extra or one uncounted line.
  defp state(key) do
    name = {__MODULE__, key}

    case :persistent_term.get(name, nil) do
      nil ->
        state = :atomics.new(2, signed: true)
        :persistent_term.put(name, state)
        state

      state ->
        state
    end
  end
end
