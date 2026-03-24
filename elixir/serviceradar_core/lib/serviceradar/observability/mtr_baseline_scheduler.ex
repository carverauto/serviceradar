defmodule ServiceRadar.Observability.MtrBaselineScheduler do
  @moduledoc """
  Periodically dispatches baseline MTR traces for enabled automation policies.
  """

  use GenServer

  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.Observability.MtrGraph
  alias ServiceRadar.Observability.MtrPolicy

  require Logger

  @default_tick_ms 60_000
  @default_prune_interval_ms to_timeout(hour: 1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, tick_interval_ms())
    prune_interval_ms = Keyword.get(opts, :prune_interval_ms, prune_interval_ms())
    send(self(), :run_baseline_tick)
    {:ok, %{tick_ms: tick_ms, prune_interval_ms: prune_interval_ms, last_prune_ms: nil}}
  end

  @impl GenServer
  def handle_info(:run_baseline_tick, state) do
    run_tick()
    state = maybe_prune_stale_edges(state)
    Process.send_after(self(), :run_baseline_tick, state.tick_ms)
    {:noreply, state}
  end

  defp run_tick do
    case MtrPolicy.list_enabled() do
      {:ok, policies} when is_list(policies) ->
        Enum.each(policies, &run_policy/1)

      {:ok, %Ash.Page.Keyset{results: policies}} ->
        Enum.each(policies, &run_policy/1)

      {:error, reason} ->
        Logger.warning("MTR baseline scheduler failed to load policies", reason: inspect(reason))
    end
  end

  defp run_policy(policy) do
    targets = MtrAutomationDispatcher.baseline_targets(policy)

    stats =
      Enum.reduce(targets, init_dispatch_stats(), fn target_ctx, acc ->
        case MtrAutomationDispatcher.dispatch_for_mode(target_ctx, policy, :baseline) do
          {:ok, _selected_agents} ->
            Map.update!(acc, :dispatched, &(&1 + 1))

          {:error, :cooldown_active} ->
            Map.update!(acc, :cooldown, &(&1 + 1))

          {:error, :no_candidates} ->
            Map.update!(acc, :no_candidates, &(&1 + 1))

          {:error, reason} ->
            reason_key = dispatch_reason_key(reason)

            acc
            |> Map.update!(:failed, &(&1 + 1))
            |> update_reason_count(reason_key)
        end
      end)

    log_dispatch_summary(
      "MTR baseline dispatch summary",
      Map.get(policy, :name),
      length(targets),
      stats
    )
  end

  defp init_dispatch_stats do
    %{
      dispatched: 0,
      cooldown: 0,
      no_candidates: 0,
      failed: 0,
      reasons: %{}
    }
  end

  defp update_reason_count(stats, reason_key) do
    Map.update!(stats, :reasons, fn reasons ->
      Map.update(reasons, reason_key, 1, &(&1 + 1))
    end)
  end

  defp dispatch_reason_key(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp dispatch_reason_key({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp dispatch_reason_key(reason), do: inspect(reason)

  defp log_dispatch_summary(prefix, policy_name, target_count, stats) do
    Logger.info(
      "#{prefix} policy=#{policy_name || "unknown"} " <>
        "targets=#{target_count} dispatched=#{stats.dispatched} cooldown=#{stats.cooldown} " <>
        "no_candidates=#{stats.no_candidates} failed=#{stats.failed} " <>
        "reasons=#{format_reason_counts(stats.reasons)}"
    )
  end

  defp format_reason_counts(reasons) when map_size(reasons) == 0, do: "none"

  defp format_reason_counts(reasons) do
    reasons
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> Enum.map_join(",", fn {key, count} -> "#{key}:#{count}" end)
  end

  defp tick_interval_ms do
    case System.get_env("MTR_BASELINE_TICK_MS") do
      nil -> Application.get_env(:serviceradar_core, :mtr_baseline_tick_ms, @default_tick_ms)
      value -> parse_int(value, @default_tick_ms)
    end
  end

  defp prune_interval_ms do
    case System.get_env("MTR_GRAPH_PRUNE_INTERVAL_MS") do
      nil ->
        Application.get_env(
          :serviceradar_core,
          :mtr_graph_prune_interval_ms,
          @default_prune_interval_ms
        )

      value ->
        parse_int(value, @default_prune_interval_ms)
    end
  end

  defp maybe_prune_stale_edges(
         %{prune_interval_ms: prune_interval_ms, last_prune_ms: last_prune_ms} = state
       ) do
    now_ms = System.monotonic_time(:millisecond)
    interval_ms = max(parse_int(prune_interval_ms, @default_prune_interval_ms), 1)

    should_prune? =
      is_nil(last_prune_ms) or
        (is_integer(last_prune_ms) and now_ms - last_prune_ms >= interval_ms)

    if should_prune? do
      MtrGraph.prune_stale_edges()
      %{state | last_prune_ms: now_ms}
    else
      state
    end
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_value, default), do: default
end
