defmodule ServiceRadar.Observability.ResolveStaleAnomaliesWorker do
  @moduledoc """
  Periodically auto-resolves stale edge-spike anomaly alerts.

  The edge anomaly add-on opens an alert (via the `causal_prediction_health_finding`
  stateful rule) when a series breaches, and a later `anomaly_clear` record resolves
  it. But if the monitored series goes silent — an ephemeral pod destroyed, a host
  decommissioned, or the series evicted at the add-on's per-host memory cap — no
  `anomaly_clear` ever arrives, so the alert sits open until manual cleanup.

  Engine-visible silence alone cannot distinguish an abandoned series from a
  still-open anomaly: ingest dedupes re-emissions by deterministic event id, so a
  sustained anomaly produces no new engine evidence after the first open.
  `platform.anomaly_episodes` does carry that liveness (add-on heartbeats refresh
  `last_seen_at`), so before resolving the worker collects the series keys of
  episodes still open within `:stale_anomaly_episode_freshness_hours` (default:
  the stale window) and the engine keeps those alerts. Alerts whose episode is
  cleared, stale-closed, or absent resolve as before; a failed episode lookup
  fails open (resolve, warning logged) so a broken episode surface cannot wedge
  alert cleanup.

  Any remaining alert that has had no matching record for
  `:stale_anomaly_resolve_hours` (default #{6}h) is resolved, routing through
  `StatefulAlertEngine.resolve_stale_anomalies/4` so the engine's in-memory snapshot
  and the Postgres `alert_id` stay consistent (a later re-anomaly opens a fresh
  alert rather than being suppressed by a stale snapshot).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Repo

  require Logger

  # The rule the edge anomaly add-on's `anomaly_open` records drive (rule_seeder).
  @rule_name "causal_prediction_health_finding"
  @default_stale_hours 6

  # Canonical series keys embed the device identity, so they are sufficient to
  # match an alert's group to its episode; the episode registry's `device_uid`
  # can differ textually from the engine's "device" group value, so requiring a
  # device match here could miss a live episode and resolve its alert.
  @live_episodes_sql """
  SELECT DISTINCT series_key
  FROM platform.anomaly_episodes
  WHERE status = 'open'
    AND last_seen_at >= $1::timestamp(6)
  """

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    hours = stale_hours()
    cutoff = DateTime.add(now, -hours * 3600, :second)
    live_series_keys = live_episode_series_keys(now)

    case StatefulAlertEngine.resolve_stale_anomalies(@rule_name, cutoff, now, live_series_keys) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info(
          "Auto-resolved #{count} stale edge-spike anomaly alert(s) " <>
            "(no matching record for #{hours}h)"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Series keys of anomaly episodes still open within `episode_freshness_hours/0`
  before `now`. The stale sweep keeps alerts for these series even though the
  engine saw no re-fire. Returns an empty set (today's resolve behavior) when
  the check is disabled or the lookup errors.
  """
  @spec live_episode_series_keys(DateTime.t(), module()) :: MapSet.t()
  def live_episode_series_keys(%DateTime{} = now, repo \\ Repo) do
    if episode_liveness_check?() do
      cutoff =
        now
        |> DateTime.add(-episode_freshness_hours() * 3600, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:microsecond)

      query_live_series_keys(cutoff, repo)
    else
      MapSet.new()
    end
  end

  defp query_live_series_keys(cutoff, repo) do
    case repo.query(@live_episodes_sql, [cutoff]) do
      {:ok, %{rows: rows}} ->
        MapSet.new(for [series_key] <- rows, is_binary(series_key), do: series_key)

      {:error, reason} ->
        log_fail_open(reason)
        MapSet.new()
    end
  rescue
    error ->
      log_fail_open(error)
      MapSet.new()
  end

  defp log_fail_open(reason) do
    Logger.warning(
      "Anomaly episode liveness lookup failed; stale sweep resolves without it: " <>
        inspect(reason)
    )
  end

  @doc "The silence window (hours) after which an open edge-spike alert auto-resolves."
  @spec stale_hours() :: pos_integer()
  def stale_hours do
    case Application.get_env(:serviceradar_core, :stale_anomaly_resolve_hours) do
      hours when is_integer(hours) and hours > 0 -> hours
      _ -> @default_stale_hours
    end
  end

  @doc "How recent (hours) an open episode's `last_seen_at` must be to keep its alert."
  @spec episode_freshness_hours() :: pos_integer()
  def episode_freshness_hours do
    case Application.get_env(:serviceradar_core, :stale_anomaly_episode_freshness_hours) do
      hours when is_integer(hours) and hours > 0 -> hours
      _ -> stale_hours()
    end
  end

  @doc "Whether the sweep consults `platform.anomaly_episodes` before resolving."
  @spec episode_liveness_check?() :: boolean()
  def episode_liveness_check? do
    Application.get_env(:serviceradar_core, :stale_anomaly_episode_liveness_check, true) != false
  end
end
