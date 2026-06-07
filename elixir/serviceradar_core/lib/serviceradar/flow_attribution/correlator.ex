defmodule ServiceRadar.FlowAttribution.Correlator do
  @moduledoc """
  Periodically correlates pushed netprobe attributions with collected NetFlow and
  stamps matching `ocsf_network_activity` flows as `attributed_flow`
  (see `ServiceRadar.FlowAttribution`), then prunes stale attributions.
  """

  use GenServer

  alias ServiceRadar.FlowAttribution

  require Logger

  @initial_delay_ms 10_000
  @interval_ms 30_000

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
    Process.send_after(self(), :correlate, @interval_ms)

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

    {:noreply, state}
  end
end
