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

  ## Backpressure / bounded protection

  Each finding triggers a serial SRQL peak-profile fetch, so an anomaly storm could
  otherwise (a) issue one DB round-trip per finding and (b) grow this GenServer's mailbox
  without bound. Two bounds keep that contained, both report-only + fail-open:

    * **Memoized peak-profile fetch.** The peak-profile SRQL query is fully determined by
      `(metric_class, metric_name, time_range, limit, timezone)` and returns every
      `(dow, hod)` bucket in one shot, so findings in a storm that share a
      `(metric_class, metric_name)` reuse a single cached fetch (short TTL). This is the
      biggest win at the lowest risk — it collapses N serial DB round-trips into one per
      TTL window. See `#{inspect(__MODULE__)}.CachedRunner`.
    * **Drop-oldest mailbox bound.** When the cast backlog exceeds `:max_mailbox`, the
      oldest queued report casts are shed and a drop count is emitted as telemetry
      `[:serviceradar, :anomaly, :disposition, :dropped]`. A dropped finding only forgoes
      its disposition annotation; ingest is never blocked and no alert is mutated.

  Report-only contract: this process emits the disposition telemetry
  `[:serviceradar, :anomaly, :disposition]` (and the drop counter above) and nothing else.
  It NEVER mutates, creates, or suppresses an alert — suppression stays gated behind
  `AnomalyDisposition.actionable?/2` (default off, per-metric-class kill switch). A
  fetch crash is caught and logged so a single malformed finding cannot take the
  reporter (or the ingest pipeline) down.

  ## Options (`start_link/1`)

    * `:name` — registered name (default `#{inspect(__MODULE__)}`)
    * `:report_opts` — keyword list forwarded verbatim to `report_finding/2`; its
      `:runner` key defaults to `ServiceRadar.Observability.SRQLRunner` (tests inject a
      stub runner so no DB is required). `:runner`/`:runner_opts` are wrapped by the
      memoizing `CachedRunner` before being forwarded.
    * `:cache_ttl_ms` — peak-profile memo TTL in ms (default `#{5_000}`).
    * `:max_mailbox` — drop-oldest threshold for queued report casts (default `#{1_000}`).
  """

  use GenServer

  alias ServiceRadar.Observability.AnomalyDisposition
  alias ServiceRadar.Observability.AnomalyDispositionReporter.CachedRunner
  alias ServiceRadar.Observability.SRQLRunner

  require Logger

  @default_cache_ttl_ms 5_000
  @default_max_mailbox 1_000
  @drop_telemetry [:serviceradar, :anomaly, :disposition, :dropped]

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
    # Unnamed (:named_table omitted) so each reporter instance — including the
    # per-test reporters — owns a distinct, private peak-profile cache referenced by tid.
    cache_table = :ets.new(:anomaly_disposition_peak_cache, [:set, :private])

    {:ok,
     %{
       report_opts: Keyword.get(opts, :report_opts, []),
       cache_table: cache_table,
       cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms),
       max_mailbox: Keyword.get(opts, :max_mailbox, @default_max_mailbox)
     }}
  end

  @impl true
  def handle_cast({:report, finding}, state) do
    state = shed_overflow(state)
    _ = safe_report(finding, state)
    {:noreply, state}
  end

  # Drop-oldest mailbox bound. During an anomaly storm the cast rate can outrun the serial
  # SRQL fetch; rather than let the mailbox grow without bound, shed the oldest queued
  # report casts down to :max_mailbox and emit a drop counter. Report-only + fail-open.
  defp shed_overflow(%{max_mailbox: max} = state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} when len > max ->
        case drain_oldest_reports(len - max, 0) do
          0 -> :ok
          dropped -> emit_drop(dropped)
        end

        state

      _ ->
        state
    end
  end

  defp drain_oldest_reports(0, dropped), do: dropped

  defp drain_oldest_reports(remaining, dropped) do
    receive do
      {:"$gen_cast", {:report, _finding}} -> drain_oldest_reports(remaining - 1, dropped + 1)
    after
      0 -> dropped
    end
  end

  defp emit_drop(count) do
    :telemetry.execute(@drop_telemetry, %{count: count}, %{reason: :mailbox_overflow})
  end

  defp safe_report(finding, state) do
    AnomalyDisposition.report_finding(finding, memoized_report_opts(state))
  rescue
    error ->
      Logger.warning("anomaly disposition report failed: #{Exception.message(error)}")
      :ignore
  catch
    kind, reason ->
      Logger.warning("anomaly disposition report crashed: #{inspect({kind, reason})}")
      :ignore
  end

  # Wrap the configured runner with the memoizing CachedRunner, carrying the real runner
  # (and its opts) as the cache-miss fallback. Every other report option passes through.
  defp memoized_report_opts(state) do
    {base_runner, report_opts} = Keyword.pop(state.report_opts, :runner, SRQLRunner)
    {base_runner_opts, report_opts} = Keyword.pop(report_opts, :runner_opts, [])

    report_opts
    |> Keyword.put(:runner, CachedRunner)
    |> Keyword.put(:runner_opts,
      cache_table: state.cache_table,
      cache_ttl_ms: state.cache_ttl_ms,
      base_runner: base_runner,
      base_runner_opts: base_runner_opts
    )
  end
end

defmodule ServiceRadar.Observability.AnomalyDispositionReporter.CachedRunner do
  @moduledoc false
  # SRQL runner shim that memoizes peak-profile query RESULTS in an ETS table keyed by the
  # query string. The peak query is fully determined by metric_class/metric_name (plus the
  # constant time_range/limit/timezone) and returns every (dow, hod) bucket, so one fetch
  # serves all findings that share a (metric_class, metric_name) within the TTL window —
  # collapsing an anomaly storm's N serial DB round-trips into one. Only `:ok` results are
  # cached so a transient failure retries instead of being pinned.
  #
  # `PeakProfile.fetcher/2` calls `runner.query(query, runner_opts)`; this module reads its
  # cache table + TTL + fallback runner from those `runner_opts`. It runs inside the owning
  # reporter process, so the `:private` ETS table is reachable.

  @spec query(String.t(), keyword()) :: term()
  def query(query, opts) do
    table = Keyword.fetch!(opts, :cache_table)
    ttl = Keyword.fetch!(opts, :cache_ttl_ms)
    base = Keyword.fetch!(opts, :base_runner)
    base_opts = Keyword.get(opts, :base_runner_opts, [])
    now = System.monotonic_time(:millisecond)

    case lookup(table, query, now) do
      {:ok, cached} ->
        cached

      :miss ->
        result = base.query(query, base_opts)
        maybe_cache(table, query, result, now + ttl)
        result
    end
  end

  defp lookup(table, query, now) do
    case :ets.lookup(table, query) do
      [{^query, result, expires_at}] when expires_at > now -> {:ok, result}
      _ -> :miss
    end
  end

  defp maybe_cache(table, query, {:ok, _rows} = result, expires_at) do
    :ets.insert(table, {query, result, expires_at})
    :ok
  end

  defp maybe_cache(_table, _query, _result, _expires_at), do: :ok
end
