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
    # Exclude :executing so the self-reschedule in perform/1 isn't deduped
    # against the still-running job (double-seed guarded by check_existing_job).
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.HTTP.EgressClient
  alias ServiceRadar.Observability.GeoIP
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.ObanFailureEventReporter
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

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

  @required_files ["GeoLite2-ASN.mmdb", "GeoLite2-Country.mmdb"]

  @doc """
  Schedules the download job if not already scheduled.
  """
  @spec ensure_scheduled() ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:ok, :disabled} | {:error, term()}
  def ensure_scheduled do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    failure_reschedule_seconds =
      Keyword.get(config, :failure_reschedule_seconds, @default_failure_reschedule_seconds)

    dir = Keyword.get(config, :dir, System.get_env("GEOLITE_MMDB_DIR") || @default_dir)

    cond do
      not enabled?(config) ->
        {:ok, :disabled}

      not ObanSupport.available?() ->
        {:error, :oban_unavailable}

      not required_files_present?(dir) ->
        case promote_scheduled_now() do
          {:ok, :promoted} ->
            {:ok, :already_scheduled}

          :none ->
            %{} |> new() |> ObanSupport.safe_insert()
        end

      check_existing_job(failure_reschedule_seconds) ->
        {:ok, :already_scheduled}

      true ->
        %{} |> new() |> ObanSupport.safe_insert()
    end
  end

  @doc """
  Downloads any missing required MMDB files without going through Oban.

  Used by web-ng (no maintenance queue) when each pod has its own emptyDir.
  """
  @spec sync_missing_files(keyword()) :: :ok | {:error, term()}
  def sync_missing_files(opts \\ []) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    dir =
      Keyword.get(opts, :dir) ||
        Keyword.get(config, :dir, System.get_env("GEOLITE_MMDB_DIR") || @default_dir)

    timeout_ms =
      Keyword.get(opts, :timeout_ms) || Keyword.get(config, :timeout_ms, @default_timeout_ms)

    files = Keyword.get(opts, :files) || Keyword.get(config, :files, @default_files)

    if required_files_present?(dir) do
      :ok
    else
      case File.mkdir_p(dir) do
        :ok ->
          Enum.each(files, fn {name, url} ->
            dest = Path.join(dir, name)

            if File.regular?(dest) do
              :ok
            else
              _ = download_file(url, dest, receive_timeout: timeout_ms)
            end
          end)

          _ = GeoIP.reload()
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_existing_job(failure_reschedule_seconds) do
    cooldown_started_at =
      DateTime.add(DateTime.utc_now(), -max(failure_reschedule_seconds, 3_600), :second)

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where:
          j.state in ["available", "scheduled", "executing", "retryable"] or
            (j.state in ["completed", "discarded"] and j.attempted_at >= ^cooldown_started_at),
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    if enabled?(config) do
      perform_enabled(job, config)
    else
      :ok
    end
  end

  defp perform_enabled(%Oban.Job{} = job, config) do
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

    # Throttle only when this pod still has the files. emptyDir is wiped on
    # restart; a global last_success_at must not skip the re-download.
    if not force? and required_files_present?(dir) and
         recently_succeeded?(settings, now, reschedule_seconds) do
      schedule_in = seconds_until_next(settings, now, reschedule_seconds)
      ObanSupport.safe_insert(new(%{}, schedule_in: schedule_in))
      :ok
    else
      record_mmdb_attempt(settings, actor, now)

      case prepare_download_dir(dir, settings, actor, now, job, failure_reschedule_seconds) do
        :ok ->
          results =
            Enum.map(files, fn {name, url} ->
              dest = Path.join(dir, name)
              download_file(url, dest, receive_timeout: timeout_ms)
            end)

          if Enum.any?(results, &match?({:error, _}, &1)) do
            record_mmdb_failure(settings, actor, now, "download_failed")
            record_handled_failure_event(job, "GeoLite MMDB download failed")
            ObanSupport.safe_insert(new(%{}, schedule_in: max(failure_reschedule_seconds, 3_600)))
            :ok
          else
            # Ensure Geolix sees newly downloaded databases without requiring a pod restart.
            _ = GeoIP.reload()
            record_mmdb_success(settings, actor, now)
            ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 3_600)))
            :ok
          end

        :skip ->
          :ok
      end
    end
  end

  defp enabled?(config) do
    Keyword.get(config, :enabled) ||
      env_enabled?("GEOLITE_MMDB_DOWNLOAD_ENABLED") ||
      env_enabled?("GEOLITE_MMDB_SCHEDULER_ENABLED")
  end

  defp env_enabled?(name) do
    name
    |> System.get_env("false")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])
  end

  defp prepare_download_dir(dir, settings, actor, now, job, failure_reschedule_seconds) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        error = "directory_unavailable: #{inspect(reason)}"

        Logger.warning("GeoLite MMDB directory unavailable",
          dir: dir,
          error: inspect(reason)
        )

        record_mmdb_failure(settings, actor, now, error)

        record_handled_failure_event(job, %File.Error{
          reason: reason,
          action: "make directory",
          path: dir
        })

        ObanSupport.safe_insert(new(%{}, schedule_in: max(failure_reschedule_seconds, 3_600)))
        :skip
    end
  end

  # Public so the CONNECT-proxy regression test can drive it; see
  # test/serviceradar/http/egress_client_test.exs. Takes EgressClient options.
  @doc false
  def download_file(url, dest_path, opts) when is_binary(url) and is_binary(dest_path) do
    # EgressClient, not the shared Finch pool: the pool cannot tunnel through
    # SERVICERADAR_EGRESS_PROXY. It streams to disk, so a large MMDB is never
    # held in memory, and only a complete 200 replaces the file.
    case EgressClient.download_to_file(url, dest_path, opts) do
      {:ok, _} = ok ->
        Logger.info("GeoLite MMDB updated: #{Path.basename(dest_path)}", file: dest_path)
        ok

      {:error, reason} = error ->
        Logger.warning("GeoLite MMDB download failed",
          url: url,
          dest: dest_path,
          error: inspect(reason)
        )

        error
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
      NetflowSettings.update_enrichment_status(s, %{geolite_mmdb_last_attempt_at: now},
        actor: actor
      )

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

  defp record_handled_failure_event(%Oban.Job{} = job, %File.Error{} = error) do
    _ = ObanFailureEventReporter.record_job_failure(job, :error, error)
    :ok
  end

  defp record_handled_failure_event(%Oban.Job{} = job, message) when is_binary(message) do
    _ = ObanFailureEventReporter.record_job_failure(job, :error, %RuntimeError{message: message})
    :ok
  end

  defp required_files_present?(dir) when is_binary(dir) do
    Enum.all?(@required_files, &File.regular?(Path.join(dir, &1)))
  end

  defp promote_scheduled_now do
    now = DateTime.utc_now()

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state == "scheduled"
      )

    case Repo.update_all(query, [set: [scheduled_at: now]], prefix: ObanSupport.prefix()) do
      {count, _} when count > 0 -> {:ok, :promoted}
      _ -> :none
    end
  end

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
