defmodule ServiceRadar.Observability.AnomalyDispositionReporter do
  @moduledoc """
  Out-of-band, report-only consumer that drives
  `ServiceRadar.Observability.AnomalyDisposition.report_finding/2` for edge anomaly
  findings (OCSF `class_uid = 2004`).

  `ServiceRadar.EventWriter.Processors.AnalyticsSignals` `cast`s each persisted
  class-2004 anomaly finding here (fire-and-forget) AFTER it has written the OCSF row,
  so the disposition runs fully decoupled from ingest and OFF the stateful-alert hot
  path (it never touches `StatefulAlertEngine` or the evaluation queue). The cast
  returns immediately, so a slow or failing SRQL peak-profile fetch can never block
  ingest.

  Report-only contract: this process emits the disposition telemetry
  `[:serviceradar, :anomaly, :disposition]` and nothing else. It NEVER mutates, creates,
  or suppresses an alert — suppression stays gated behind
  `AnomalyDisposition.actionable?/2` (default off, per-metric-class kill switch). A
  fetch crash is caught and logged so a single malformed finding cannot take the
  reporter (or the ingest pipeline) down.

  ## Options (`start_link/1`)

    * `:name` — registered name (default `#{inspect(__MODULE__)}`)
    * `:report_opts` — keyword list forwarded verbatim to `report_finding/2`; its
      `:runner` key defaults to `ServiceRadar.Observability.SRQLRunner` (tests inject a
      stub runner so no DB is required).
  """

  use GenServer

  alias ServiceRadar.Observability.AnomalyDisposition

  require Logger

  @doc "Start the reporter. See the moduledoc for supported options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Fire-and-forget report request for a class-2004 anomaly finding already shaped for
  `AnomalyDisposition.report_finding/2` (`%{source_identity, episode_peak_value,
  episode_peak_at_unix_nano}`).

  Returns `:ok` immediately. A no-op (still `:ok`) when the reporter is not running, so
  a missing/restarting reporter can never break or block ingest.
  """
  @spec report(map(), GenServer.server()) :: :ok
  def report(finding, server \\ __MODULE__) when is_map(finding) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:report, finding})
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{report_opts: Keyword.get(opts, :report_opts, [])}}
  end

  @impl true
  def handle_cast({:report, finding}, state) do
    _ = safe_report(finding, state.report_opts)
    {:noreply, state}
  end

  defp safe_report(finding, report_opts) do
    AnomalyDisposition.report_finding(finding, report_opts)
  rescue
    error ->
      Logger.warning("anomaly disposition report failed: #{Exception.message(error)}")
      :ignore
  catch
    kind, reason ->
      Logger.warning("anomaly disposition report crashed: #{inspect({kind, reason})}")
      :ignore
  end
end
