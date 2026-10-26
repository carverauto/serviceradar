defmodule ServiceRadar.FlowAttribution.Correlator do
  @moduledoc """
  Periodically correlates netprobe attribution observations with collected
  NetFlow in the warehouse and stamps matching `ocsf_network_activity` flows as
  `attributed_flow` (see `ServiceRadar.FlowAttribution.Correlation`).

  Runs under `ServiceRadar.EventWriter.CoordinatorSupervisor`, which the cluster
  coordinator starts on one node. The next tick is scheduled only *after* the
  current pass finishes, so a slow pass cannot pile up overlapping ticks.
  Observations expire with their warehouse partitions, so there is nothing to
  prune here. Without
  StarRocks a pass is a no-op (`{:ok, :not_applicable}`); otherwise every pass,
  successful or not, reports its health through `PassMetrics`.

  Failed passes use `ServiceRadar.Backoff`. Operator-facing retry timing and
  failure logging are documented in `docs/docs/netprobe.md`, under
  "No attributed flows".

  A runtime kill switch (`FLOW_ATTRIBUTION_CORRELATOR_ENABLED`, or the
  `:flow_attribution_correlator_enabled` app env) lets operators pause just this
  loop without disabling the rest of the EventWriter.
  """

  use GenServer

  alias ServiceRadar.Backoff
  alias ServiceRadar.FlowAttribution.Correlation
  alias ServiceRadar.FlowAttribution.PassMetrics

  require Logger

  @initial_delay_ms 10_000
  # Re-correlation cadence. Each pass re-reads the recent unattributed flows (see
  # Correlation), so this governs how often that window is re-scanned; 2 min keeps
  # delayed-correlation latency well inside it. Override via
  # FLOW_ATTRIBUTION_CORRELATOR_INTERVAL_MS or :flow_attribution_correlator_interval_ms.
  @default_interval_ms 120_000

  @doc """
  Options (tests): `:name`, and `:pass_opts` / `:report_opts`, passed to
  `Correlation.run_pass/1` and `PassMetrics.report/4`.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :correlate, @initial_delay_ms)

    {:ok,
     %{
       pass_opts: Keyword.get(opts, :pass_opts, []),
       report_opts: Keyword.get(opts, :report_opts, []),
       failing: nil
     }}
  end

  @impl true
  def handle_info(:correlate, state) do
    {delay_ms, state} =
      if enabled?() do
        state |> run_once() |> next_delay()
      else
        {interval_ms(), state}
      end

    # Schedule the next tick only after the current pass completes so a slow pass
    # cannot leave a backlog of :correlate messages that then run back-to-back.
    Process.send_after(self(), :correlate, delay_ms)
    {:noreply, state}
  end

  defp interval_ms do
    case System.get_env("FLOW_ATTRIBUTION_CORRELATOR_INTERVAL_MS") do
      nil ->
        Application.get_env(
          :serviceradar_core,
          :flow_attribution_correlator_interval_ms,
          @default_interval_ms
        )

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {ms, _} when ms > 0 -> ms
          _ -> @default_interval_ms
        end
    end
  end

  defp run_once(state) do
    started_at = System.monotonic_time(:millisecond)
    {result, matches_by_rank} = Correlation.run_pass(state.pass_opts)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    if result != {:ok, :not_applicable} do
      PassMetrics.report(result, duration_ms, matches_by_rank, state.report_opts)
    end

    {result, state}
  end

  defp next_delay({{:error, reason}, %{failing: nil} = state}) do
    Logger.warning(
      "FlowAttribution.Correlator correlate failed, backing off until a pass succeeds: " <>
        inspect(reason)
    )

    # A pass reads the flows of the last window, so a retry later than that
    # would skip flows entirely; the backoff stops there, or at the interval
    # when that is configured longer.
    interval = interval_ms()
    max_ms = max(Correlation.flows_window_minutes() * 60_000, interval)
    backoff = Backoff.new(base_ms: min(2 * interval, max_ms), max_ms: max_ms, jitter: 0.0)
    failed({1, backoff}, state)
  end

  defp next_delay({{:error, _reason}, %{failing: {passes, backoff}} = state}),
    do: failed({passes + 1, backoff}, state)

  defp next_delay({result, state}) do
    with {passes, _backoff} <- state.failing do
      Logger.info("FlowAttribution.Correlator recovered after #{passes} failed pass(es)")
    end

    case result do
      {:ok, count} when is_integer(count) and count > 0 ->
        Logger.info("FlowAttribution.Correlator stamped #{count} flow(s) as attributed")

      _ ->
        :ok
    end

    {interval_ms(), %{state | failing: nil}}
  end

  defp failed({passes, backoff}, state) do
    {delay_ms, backoff} = Backoff.next(backoff)
    {delay_ms, %{state | failing: {passes, backoff}}}
  end

  defp enabled? do
    case System.get_env("FLOW_ATTRIBUTION_CORRELATOR_ENABLED") do
      nil ->
        Application.get_env(:serviceradar_core, :flow_attribution_correlator_enabled, true)

      value when is_binary(value) ->
        String.downcase(String.trim(value)) not in ~w(0 false no off disabled)
    end
  end
end
