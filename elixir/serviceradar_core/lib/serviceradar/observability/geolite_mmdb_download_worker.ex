defmodule ServiceRadar.Observability.GeoLiteMmdbDownloadWorker do
  @moduledoc """
  Downloads GeoLite2 MMDB databases for local GeoIP/ASN enrichment.

  The NetFlow enrichment pipeline must use local databases (no API calls at query time).
  This worker refreshes the local copies on a daily schedule.

  Source:
  - https://github.com/P3TERX/GeoLite.mmdb (raw GitHub download links)
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Daily refresh; don't let retries/parallel instances hammer GitHub.
    unique: [period: 86_400, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.GeoIP
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]

  require Logger

  @default_dir "/var/lib/serviceradar/geoip"
  # GeoLite2-City is ~60MB; 20s is frequently too aggressive in Kubernetes.
  @default_timeout_ms 180_000
  @default_reschedule_seconds 86_400
  # If a download fails (429/network policy, etc.), back off instead of retrying immediately.
  @default_failure_reschedule_seconds 6 * 3600

  @default_files %{
    "GeoLite2-ASN.mmdb" =>
      "https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-ASN.mmdb",
    "GeoLite2-City.mmdb" =>
      "https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-City.mmdb",
    "GeoLite2-Country.mmdb" =>
      "https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb"
  }

  @doc """
  Schedules the download job if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case check_existing_job() do
        true -> {:ok, :already_scheduled}
        false -> %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    dir = Keyword.get(config, :dir, System.get_env("GEOLITE_MMDB_DIR") || @default_dir)
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)
    failure_reschedule_seconds =
      Keyword.get(config, :failure_reschedule_seconds, @default_failure_reschedule_seconds)
    files = Keyword.get(config, :files, @default_files)

    now = DateTime.utc_now()
    actor = SystemActor.system(:geolite_mmdb_download)
    force? = Map.get(job.args || %{}, "force") == true
    settings = load_settings(actor)

    # Throttle: this job may be manually triggered; skip if we've refreshed recently unless forced.
    if not force? and recently_succeeded?(settings, now, reschedule_seconds) do
      schedule_in = seconds_until_next(settings, now, reschedule_seconds)
      ObanSupport.safe_insert(new(%{}, schedule_in: schedule_in))
      :ok
    else
      record_mmdb_attempt(settings, actor, now)

      File.mkdir_p!(dir)

      results =
        files
        |> Enum.map(fn {name, url} ->
          dest = Path.join(dir, name)
          download_file(url, dest, timeout_ms)
        end)

      if Enum.any?(results, &match?({:error, _}, &1)) do
        record_mmdb_failure(settings, actor, now, "download_failed")
        ObanSupport.safe_insert(new(%{}, schedule_in: max(failure_reschedule_seconds, 3_600)))
        :ok
      else
        # Ensure Geolix sees newly downloaded databases without requiring a pod restart.
        _ = GeoIP.reload()
        record_mmdb_success(settings, actor, now)
        ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 3_600)))
        :ok
      end
    end
  end

  defp download_file(url, dest_path, timeout_ms) when is_binary(url) and is_binary(dest_path) do
    tmp = dest_path <> ".tmp"

    File.rm(tmp)

    req_opts = [
      receive_timeout: timeout_ms,
      retry: false,
      finch: ServiceRadar.Finch
    ]

    try do
      # Stream to disk to avoid loading large MMDBs in memory.
      _resp =
        url
        |> Req.get!(req_opts ++ [into: File.stream!(tmp)])

      File.rename!(tmp, dest_path)
      Logger.info("GeoLite MMDB updated: #{Path.basename(dest_path)}", file: dest_path)
      {:ok, dest_path}
    rescue
      e ->
        File.rm(tmp)

        Logger.warning("GeoLite MMDB download failed",
          url: url,
          dest: dest_path,
          error: inspect(e)
        )

        {:error, e}
    end
  end

  defp load_settings(actor) do
    case NetflowSettings.get_settings(actor: actor) do
      {:ok, %NetflowSettings{} = s} ->
        s

      _ ->
        case NetflowSettings.create(%{}, actor: actor) do
          {:ok, %NetflowSettings{} = s} -> s
          _ -> nil
        end
    end
  end

  defp record_mmdb_attempt(%NetflowSettings{} = s, actor, %DateTime{} = now) do
    _ =
      NetflowSettings.update_enrichment_status(s, %{geolite_mmdb_last_attempt_at: now}, actor: actor)

    :ok
  end

  defp record_mmdb_attempt(_settings, _actor, _now), do: :ok

  defp record_mmdb_success(%NetflowSettings{} = s, actor, %DateTime{} = now) do
    _ =
      NetflowSettings.update_enrichment_status(
        s,
        %{
          geolite_mmdb_last_success_at: now,
          geolite_mmdb_last_error: nil
        },
        actor: actor
      )

    :ok
  end

  defp record_mmdb_success(_settings, _actor, _now), do: :ok

  defp record_mmdb_failure(%NetflowSettings{} = s, actor, %DateTime{} = _now, err) do
    _ =
      NetflowSettings.update_enrichment_status(
        s,
        %{
          geolite_mmdb_last_error: to_string(err)
        },
        actor: actor
      )

    :ok
  end

  defp record_mmdb_failure(_settings, _actor, _now, _err), do: :ok

  defp recently_succeeded?(%NetflowSettings{} = s, %DateTime{} = now, seconds)
       when is_integer(seconds) and seconds > 0 do
    case Map.get(s, :geolite_mmdb_last_success_at) do
      %DateTime{} = last ->
        DateTime.diff(now, last, :second) < seconds - 600

      _ ->
        false
    end
  end

  defp recently_succeeded?(_settings, _now, _seconds), do: false

  defp seconds_until_next(%NetflowSettings{} = s, %DateTime{} = now, seconds)
       when is_integer(seconds) and seconds > 0 do
    case Map.get(s, :geolite_mmdb_last_success_at) do
      %DateTime{} = last ->
        elapsed = max(DateTime.diff(now, last, :second), 0)
        max(seconds - elapsed, 3_600)

      _ ->
        max(seconds, 3_600)
    end
  end

  defp seconds_until_next(_settings, _now, seconds) when is_integer(seconds),
    do: max(seconds, 3_600)
end
