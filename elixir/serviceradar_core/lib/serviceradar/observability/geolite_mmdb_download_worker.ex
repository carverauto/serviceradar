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
    unique: [period: 3600, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Repo
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]

  require Logger

  @default_dir "/var/lib/serviceradar/geoip"
  @default_timeout_ms 20_000
  @default_reschedule_seconds 86_400

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
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    dir = Keyword.get(config, :dir, System.get_env("GEOLITE_MMDB_DIR") || @default_dir)
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)
    files = Keyword.get(config, :files, @default_files)

    now = DateTime.utc_now()
    actor = SystemActor.system(:geolite_mmdb_download)
    record_mmdb_attempt(actor, now)

    File.mkdir_p!(dir)

    results =
      files
      |> Enum.map(fn {name, url} ->
        dest = Path.join(dir, name)
        download_file(url, dest, timeout_ms)
      end)

    if Enum.any?(results, &match?({:error, _}, &1)) do
      record_mmdb_failure(actor, now, "download_failed")
      {:error, :download_failed}
    else
      record_mmdb_success(actor, now)
      ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 3_600)))
      :ok
    end
  end

  defp download_file(url, dest_path, timeout_ms) when is_binary(url) and is_binary(dest_path) do
    tmp = dest_path <> ".tmp"

    File.rm(tmp)

    req_opts = [
      receive_timeout: timeout_ms,
      connect_options: [timeout: timeout_ms]
    ]

    try do
      # Stream to disk to avoid loading large MMDBs in memory.
      _resp =
        url
        |> Req.get!(req_opts ++ [into: File.stream!(tmp)])

      File.rename!(tmp, dest_path)
      Logger.info("GeoLite MMDB updated", file: dest_path)
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

  defp record_mmdb_attempt(actor, %DateTime{} = now) do
    case load_settings(actor) do
      %NetflowSettings{} = s ->
        _ =
          NetflowSettings.update_enrichment_status(s, %{geolite_mmdb_last_attempt_at: now},
            actor: actor
          )

        :ok

      _ ->
        :ok
    end
  end

  defp record_mmdb_success(actor, %DateTime{} = now) do
    case load_settings(actor) do
      %NetflowSettings{} = s ->
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

      _ ->
        :ok
    end
  end

  defp record_mmdb_failure(actor, %DateTime{} = _now, err) do
    case load_settings(actor) do
      %NetflowSettings{} = s ->
        _ =
          NetflowSettings.update_enrichment_status(
            s,
            %{
              geolite_mmdb_last_error: to_string(err)
            },
            actor: actor
          )

        :ok

      _ ->
        :ok
    end
  end
end
