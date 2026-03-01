defmodule ServiceRadar.Observability.MtrBaselineScheduler do
  @moduledoc """
  Periodically dispatches baseline MTR traces for enabled automation policies.
  """

  use GenServer

  alias ServiceRadar.Observability.{MtrAutomationDispatcher, MtrPolicy}

  require Logger

  @default_tick_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, tick_interval_ms())
    send(self(), :run_baseline_tick)
    {:ok, %{tick_ms: tick_ms}}
  end

  @impl GenServer
  def handle_info(:run_baseline_tick, state) do
    run_tick()
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

    Enum.each(targets, fn target_ctx ->
      case MtrAutomationDispatcher.dispatch_for_mode(target_ctx, policy, :baseline) do
        {:ok, _selected_agents} ->
          :ok

        {:error, :cooldown_active} ->
          :ok

        {:error, :no_candidates} ->
          :ok

        {:error, reason} ->
          Logger.debug("MTR baseline dispatch skipped",
            policy: Map.get(policy, :name),
            target_key: Map.get(target_ctx, :target_key),
            reason: inspect(reason)
          )
      end
    end)
  end

  defp tick_interval_ms do
    case System.get_env("MTR_BASELINE_TICK_MS") do
      nil -> Application.get_env(:serviceradar_core, :mtr_baseline_tick_ms, @default_tick_ms)
      value -> parse_int(value, @default_tick_ms)
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
