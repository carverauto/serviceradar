defmodule ServiceRadar.Observability.MtrBaselineScheduler do
  @moduledoc """
  Periodically dispatches baseline MTR traces for enabled automation policies.
  """

  use GenServer

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.Observability.MtrGraph
  alias ServiceRadar.Observability.MtrPolicy
  alias ServiceRadar.Repo

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
    safe_run_tick()
    state = maybe_prune_stale_edges(state)
    Process.send_after(self(), :run_baseline_tick, state.tick_ms)
    {:noreply, state}
  end

  defp safe_run_tick do
    run_tick()
  rescue
    exception ->
      Logger.error("MTR baseline scheduler tick failed: #{Exception.message(exception)}")
  catch
    kind, reason ->
      Logger.error("MTR baseline scheduler tick failed: #{inspect({kind, reason})}")
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

    if bulk_baseline_policy?(policy) do
      stats = run_bulk_policy(policy, targets)

      log_dispatch_summary(
        "MTR baseline bulk dispatch summary",
        Map.get(policy, :name),
        length(targets),
        stats
      )
    else
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
  end

  defp run_bulk_policy(policy, targets) do
    actor = ServiceRadar.Actors.SystemActor.system(:mtr_automation)
    selector = Map.get(policy, :target_selector, %{}) || %{}
    agent_id = Map.get(selector, "agent_id")
    interval = Map.get(policy, :baseline_interval_sec) || 300
    concurrency = selector_int(selector, "bulk_concurrency")
    execution_profile = Map.get(selector, "bulk_execution_profile")

    with true <- is_binary(agent_id) and agent_id != "",
         {:ok, :ready} <- ensure_bulk_policy_ready(policy.id, interval),
         bulk_targets when bulk_targets != [] <- extract_bulk_targets(targets),
         {:ok, _command_id} <-
           AgentCommandBus.dispatch_bulk_mtr(
             agent_id,
             bulk_targets,
             protocol: Map.get(policy, :baseline_protocol),
             concurrency: concurrency,
             execution_profile: execution_profile,
             actor: actor,
             context: %{
               "trigger_mode" => "baseline",
               "mtr_policy_id" => policy.id,
               "bulk_scheduler" => true
             }
           ) do
      %{dispatched: length(bulk_targets), cooldown: 0, no_candidates: 0, failed: 0, reasons: %{}}
    else
      {:error, :cooldown_active} ->
        %{dispatched: 0, cooldown: length(targets), no_candidates: 0, failed: 0, reasons: %{}}

      false ->
        %{dispatched: 0, cooldown: 0, no_candidates: length(targets), failed: 0, reasons: %{}}

      [] ->
        %{dispatched: 0, cooldown: 0, no_candidates: 0, failed: 0, reasons: %{}}

      {:error, {:agent_busy, :bulk_mtr_job_running}} ->
        %{
          dispatched: 0,
          cooldown: length(targets),
          no_candidates: 0,
          failed: 0,
          reasons: %{"bulk_overlap" => 1}
        }

      {:error, :preferred_agent_unavailable} ->
        %{dispatched: 0, cooldown: 0, no_candidates: length(targets), failed: 0, reasons: %{}}

      {:error, reason} ->
        %{
          dispatched: 0,
          cooldown: 0,
          no_candidates: 0,
          failed: 1,
          reasons: %{dispatch_reason_key(reason) => 1}
        }
    end
  end

  defp bulk_baseline_policy?(policy) do
    selector = Map.get(policy, :target_selector, %{}) || %{}

    preferred_agent? =
      is_binary(Map.get(selector, "agent_id")) and Map.get(selector, "agent_id") != ""

    canaries = Map.get(policy, :baseline_canary_vantages) || 0
    preferred_agent? and canaries == 0
  end

  defp extract_bulk_targets(targets) do
    targets
    |> Enum.map(fn target_ctx ->
      Map.get(target_ctx, :target) || Map.get(target_ctx, :target_ip)
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp ensure_bulk_policy_ready(policy_id, interval_seconds) do
    query = """
    SELECT status, inserted_at, completed_at, expires_at
    FROM platform.agent_commands
    WHERE command_type = 'mtr.bulk_run'
      AND (
        CASE
          WHEN jsonb_typeof(context) = 'object' THEN context ->> 'mtr_policy_id'
          WHEN jsonb_typeof(context) = 'string' AND left(context #>> '{}', 1) = '{' THEN
            (context #>> '{}')::jsonb ->> 'mtr_policy_id'
          ELSE NULL
        END
      ) = $1
    ORDER BY inserted_at DESC
    LIMIT 1
    """

    case Repo.query(query, [to_string(policy_id)]) do
      {:ok, %{rows: [[status, _inserted_at, completed_at, expires_at]]}} ->
        completed_at = normalize_datetime(completed_at)
        expires_at = normalize_datetime(expires_at)

        active_unexpired? =
          status in ["queued", "sent", "acknowledged", "running"] and
            (is_nil(expires_at) or DateTime.after?(expires_at, DateTime.utc_now()))

        cond do
          active_unexpired? ->
            {:error, :cooldown_active}

          match?(%DateTime{}, completed_at) and
              DateTime.diff(DateTime.utc_now(), completed_at, :second) < interval_seconds ->
            {:error, :cooldown_active}

          true ->
            {:ok, :ready}
        end

      {:ok, %{rows: []}} ->
        {:ok, :ready}

      {:error, reason} ->
        Logger.warning("MTR bulk baseline readiness query failed", reason: inspect(reason))
        {:error, reason}
    end
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

  defp selector_int(selector, key) when is_map(selector) do
    case Map.get(selector, key) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(%NaiveDateTime{} = value) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp normalize_datetime(_value), do: nil
end
