defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditions do
  @moduledoc """
  Process-free tracker for persistent topology health conditions.

  Backed by `:persistent_term` so state transitions (healthy -> unhealthy and
  back) are detectable without a DB round-trip or a dedicated process.
  Repeated identical failures deduplicate into one ongoing condition: the
  transition logs loudly (error level), steady-state repeats log at info with
  an `ongoing_failure` flag, and recovery logs an explicit all-clear.

  `:persistent_term` is per-node and wiped on restart — acceptable here: after
  a restart the first failing run re-logs the transition at error level, which
  is exactly the loud signal we want. Writes only happen on failure occurrences
  and transitions (hourly cadence at worst), so persistent_term GC pressure is
  a non-issue.
  """

  require Logger

  @typedoc "Identifier for a tracked condition (an atom in production code)."
  @type condition :: term()

  @type state :: %{
          status: :unhealthy,
          since: DateTime.t(),
          last_seen: DateTime.t(),
          occurrences: pos_integer(),
          details: map()
        }

  @spec unhealthy?(condition()) :: boolean()
  def unhealthy?(condition), do: get(condition) != nil

  @spec get(condition()) :: state() | nil
  def get(condition), do: :persistent_term.get(key(condition), nil)

  @doc "Removes any tracked state for the condition (test/ops helper)."
  @spec clear(condition()) :: :ok
  def clear(condition) do
    _ = :persistent_term.erase(key(condition))
    :ok
  end

  @doc """
  Records a failure occurrence and logs it with transition-aware severity.

  Returns `:new_failure` when the condition transitions from healthy (logged
  at error level) or `:ongoing_failure` when it was already unhealthy (logged
  at info level with `ongoing_failure: true` so steady-state repeats do not
  spam the error log).
  """
  @spec report_failure(condition(), String.t(), keyword()) :: :new_failure | :ongoing_failure
  def report_failure(condition, message, metadata \\ []) when is_binary(message) do
    case mark_unhealthy(condition, metadata) do
      {:new_failure, state} ->
        Logger.error(
          message,
          metadata ++
            [health_condition: condition, since: state.since, occurrences: state.occurrences]
        )

        :new_failure

      {:ongoing_failure, state} ->
        Logger.info(
          message <> " (ongoing failure)",
          metadata ++
            [
              health_condition: condition,
              ongoing_failure: true,
              since: state.since,
              occurrences: state.occurrences
            ]
        )

        :ongoing_failure
    end
  end

  @doc """
  Records recovery. When the condition was unhealthy the all-clear is logged
  and `:recovered` returned; when already healthy nothing is logged or written
  (read-only fast path safe to call on every healthy run).
  """
  @spec report_recovery(condition(), String.t(), keyword()) :: :recovered | :already_healthy
  def report_recovery(condition, message, metadata \\ []) when is_binary(message) do
    case mark_healthy(condition) do
      {:recovered, prior} ->
        Logger.info(
          message,
          metadata ++
            [
              health_condition: condition,
              recovered: true,
              failed_since: prior.since,
              failed_occurrences: prior.occurrences
            ]
        )

        :recovered

      :already_healthy ->
        :already_healthy
    end
  end

  @doc false
  @spec mark_unhealthy(condition(), keyword() | map()) ::
          {:new_failure, state()} | {:ongoing_failure, state()}
  def mark_unhealthy(condition, details \\ []) do
    now = DateTime.utc_now()
    details = Map.new(details)

    case get(condition) do
      nil ->
        state = %{
          status: :unhealthy,
          since: now,
          last_seen: now,
          occurrences: 1,
          details: details
        }

        :ok = :persistent_term.put(key(condition), state)
        {:new_failure, state}

      %{} = state ->
        state = %{state | last_seen: now, occurrences: state.occurrences + 1, details: details}
        :ok = :persistent_term.put(key(condition), state)
        {:ongoing_failure, state}
    end
  end

  @doc false
  @spec mark_healthy(condition()) :: {:recovered, state()} | :already_healthy
  def mark_healthy(condition) do
    case get(condition) do
      nil ->
        :already_healthy

      %{} = state ->
        _ = :persistent_term.erase(key(condition))
        {:recovered, state}
    end
  end

  defp key(condition), do: {__MODULE__, condition}
end
