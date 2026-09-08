defmodule ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker do
  @moduledoc """
  Closes anomaly episodes that stopped receiving producer updates.

  Edge producers normally emit explicit clear transitions. If an addon crashes,
  restarts without checkpoint state, or a series disappears before that clear is
  emitted, the bounded `platform.anomaly_episodes` surface must still converge.
  This worker marks long-silent open episodes as `stale_closed`.

  Unless a stale window is configured explicitly, the threshold is derived per
  run from the emission settings as twice the episode heartbeat interval
  (`episode_update_interval_secs`), floored at 30 minutes, so a single delayed
  heartbeat cannot stale-close a live episode.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Repo

  require Logger

  @default_stale_minutes 30

  @close_sql """
  UPDATE platform.anomaly_episodes
  SET
    status = 'stale_closed',
    cleared_at = $2::timestamp(6),
    clear_reason = 'stale',
    last_transition = 'stale',
    updated_at = (now() AT TIME ZONE 'utc')
  WHERE status = 'open'
    AND last_seen_at < $1::timestamp(6)
  """

  @impl Oban.Worker
  def perform(_job) do
    now = now_naive()
    cutoff = NaiveDateTime.add(now, -stale_after_seconds(), :second)

    case close_stale(cutoff, now) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Closed stale anomaly episode(s)", count: count, cutoff: cutoff)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec close_stale(NaiveDateTime.t(), NaiveDateTime.t(), module()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def close_stale(%NaiveDateTime{} = cutoff, %NaiveDateTime{} = now, repo \\ Repo) do
    case repo.query(@close_sql, [cutoff, now]) do
      {:ok, %{num_rows: count}} when is_integer(count) -> {:ok, count}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    minutes =
      Keyword.get(config, :stale_after_minutes) ||
        Application.get_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    case minutes do
      value when is_integer(value) and value > 0 -> value * 60
      _ -> max(2 * heartbeat_interval_secs(config), @default_stale_minutes * 60)
    end
  end

  defp heartbeat_interval_secs(config) do
    case fetch_settings(config) do
      {:ok, %AnomalyDetectionConfig{emission: %{} = emission}} ->
        emission
        |> Map.get("episode_update_interval_secs")
        |> normalize_heartbeat()

      _ ->
        default_heartbeat_secs()
    end
  end

  defp fetch_settings(config) do
    case Keyword.get(config, :settings_fetcher) do
      fun when is_function(fun, 0) ->
        fun.()

      nil ->
        AnomalyDetectionConfig.get_settings(
          actor: SystemActor.system(:anomaly_episode_stale_close)
        )
    end
  rescue
    error ->
      Logger.warning("Failed to load anomaly emission settings for stale-close margin",
        reason: Exception.message(error)
      )

      :error
  end

  defp normalize_heartbeat(value) when is_integer(value) and value > 0, do: value

  defp normalize_heartbeat(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> default_heartbeat_secs()
    end
  end

  defp normalize_heartbeat(_value), do: default_heartbeat_secs()

  defp default_heartbeat_secs, do: AnomalyDetectionConfig.default_episode_update_interval_secs()

  defp now_naive do
    DateTime.utc_now()
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:microsecond)
  end
end
