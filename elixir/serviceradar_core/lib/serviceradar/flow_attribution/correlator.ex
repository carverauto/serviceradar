defmodule ServiceRadar.FlowAttribution.Correlator do
  @moduledoc """
  Periodically correlates pushed netprobe attributions with collected NetFlow and
  stamps matching `ocsf_network_activity` flows as `attributed_flow`
  (see `ServiceRadar.FlowAttribution`), then prunes stale attributions.

  Cross-node safety: the correlation statement itself is guarded by a Postgres
  advisory lock (see `ServiceRadar.FlowAttribution.Correlation`), so even when
  this GenServer runs on multiple `core` replicas only one node performs a
  correlation pass at a time. The work is also bounded per pass and the next tick
  is scheduled only *after* the current pass finishes, so a slow pass cannot pile
  up overlapping ticks.

  A runtime kill switch (`FLOW_ATTRIBUTION_CORRELATOR_ENABLED`, or the
  `:flow_attribution_correlator_enabled` app env) lets operators pause just this
  loop without disabling the rest of the EventWriter.
  """

  use GenServer

  alias ServiceRadar.FlowAttribution

  require Logger

  @initial_delay_ms 10_000
  # Re-correlation cadence. The correlation WINDOW is 30 min (see Correlation), so
  # this only governs how often that window is re-scanned. At 30s a 30-min window
  # was re-scanned ~60x per row, churning millions of index-heavy UPDATEs on
  # flow_process_attribution_current. 2 min keeps delayed-correlation latency well
  # inside the window while cutting that re-scan load ~4x. Override via
  # FLOW_ATTRIBUTION_CORRELATOR_INTERVAL_MS or :flow_attribution_correlator_interval_ms.
  @default_interval_ms 120_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :correlate, @initial_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:correlate, state) do
    if enabled?() do
      run_once()
    end

    # Schedule the next tick only after the current pass completes so a slow pass
    # cannot leave a backlog of :correlate messages that then run back-to-back.
    Process.send_after(self(), :correlate, interval_ms())
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

  defp run_once do
    case FlowAttribution.correlate() do
      {:ok, count} when count > 0 ->
        Logger.info("FlowAttribution.Correlator stamped #{count} flow(s) as attributed")

      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("FlowAttribution.Correlator correlate failed: #{inspect(reason)}")
    end

    case FlowAttribution.prune() do
      {:error, reason} ->
        Logger.warning("FlowAttribution.Correlator prune failed: #{inspect(reason)}")

      _ ->
        :ok
    end
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
