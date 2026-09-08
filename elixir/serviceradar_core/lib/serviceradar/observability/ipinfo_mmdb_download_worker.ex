defmodule ServiceRadar.Observability.IpinfoMmdbDownloadWorker do
  @moduledoc """
  Downloads the ipinfo.io lite MMDB database for local IP enrichment.

  This replaces expensive per-IP API calls with a local MaxMind-style database lookup.

  Source:
  - https://ipinfo.io/data/ipinfo_lite.mmdb?token=<token>
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Observability.GeoIP
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_dir "/var/lib/serviceradar/geoip"
  @default_timeout_ms 180_000
  @default_reschedule_seconds 86_400
  @default_failure_reschedule_seconds 6 * 3600
  @mmdb_filename "ipinfo_lite.mmdb"

  @doc """
  Schedules the download job if not already scheduled.
  """
  @spec ensure_scheduled() ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:ok, :disabled} | {:error, term()}
  def ensure_scheduled do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    dir = Keyword.get(config, :dir, System.get_env("GEOLITE_MMDB_DIR") || @default_dir)

    cond do
      not enabled?(config) ->
        {:ok, :disabled}

      not ObanSupport.available?() ->
        {:error, :oban_unavailable}

      not file_present?(dir) ->
        case promote_scheduled_now() do
          {:ok, :promoted} ->
            {:ok, :already_scheduled}

          :none ->
            %{} |> new() |> ObanSupport.safe_insert()
        end

      check_existing_job() ->
        {:ok, :already_scheduled}

      true ->
        %{} |> new() |> ObanSupport.safe_insert()
    end
  end

  @doc """
  Downloads `ipinfo_lite.mmdb` when it is missing and a token is configured.

  Used by web-ng (no maintenance queue) when each pod has its own emptyDir.
  """
  @spec sync_missing_files(keyword()) :: :ok | {:error, term()} | {:ok, :skipped}
  def sync_missing_files(opts \\ []) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    dir =
      Keyword.get(opts, :dir) ||
        Keyword.get(config, :dir, System.get_env("GEOLITE_MMDB_DIR") || @default_dir)

    timeout_ms =
      Keyword.get(opts, :timeout_ms) || Keyword.get(config, :timeout_ms, @default_timeout_ms)

    dest = Path.join(dir, @mmdb_filename)

    if file_present?(dir) do
      :ok
    else
      actor = SystemActor.system(:ipinfo_mmdb_download)
      token = download_token(load_settings(actor))

      if token == "" do
        {:ok, :skipped}
      else
        case File.mkdir_p(dir) do
          :ok ->
            case download_file(build_url(token), dest, timeout_ms) do
              {:ok, _} ->
                _ = GeoIP.reload()
                :ok

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
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

    actor = SystemActor.system(:ipinfo_mmdb_download)
    settings = load_settings(actor)
    force? = Map.get(job.args || %{}, "force") == true

    token = download_token(settings)
    dest = Path.join(dir, @mmdb_filename)

    cond do
      token == "" ->
        Logger.info("Ipinfo MMDB download skipped (token missing or ipinfo disabled)")
        schedule_next(reschedule_seconds)

      not force? and recently_updated?(dest, reschedule_seconds) ->
        schedule_next(reschedule_seconds)

      true ->
        download_mmdb(
          dir,
          token,
          dest,
          timeout_ms,
          reschedule_seconds,
          failure_reschedule_seconds
        )
    end
  end

  defp download_mmdb(dir, token, dest, timeout_ms, reschedule_seconds, failure_reschedule_seconds) do
    case File.mkdir_p(dir) do
      :ok ->
        url = build_url(token)

        case download_file(url, dest, timeout_ms) do
          {:ok, _} ->
            _ = GeoIP.reload()
            schedule_next(reschedule_seconds)

          {:error, reason} ->
            Logger.warning("Ipinfo MMDB download failed", error: inspect(reason))
            schedule_next(failure_reschedule_seconds)
        end

      {:error, reason} ->
        Logger.warning("Ipinfo MMDB directory unavailable", dir: dir, error: inspect(reason))
        schedule_next(failure_reschedule_seconds)
    end
  end

  defp enabled?(config) do
    Keyword.get(config, :enabled) ||
      env_enabled?("IPINFO_MMDB_DOWNLOAD_ENABLED") ||
      env_enabled?("IPINFO_MMDB_SCHEDULER_ENABLED")
  end

  defp env_enabled?(name) do
    name
    |> System.get_env("false")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])
  end

  defp schedule_next(seconds) when is_integer(seconds) do
    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, max(seconds, 3_600))
      )

    :ok
  end

  defp download_token(%NetflowSettings{} = s) do
    if s.ipinfo_enabled == true do
      token = Map.get(s, :ipinfo_api_key)
      if is_binary(token), do: String.trim(token), else: ""
    else
      ""
    end
  end

  defp download_token(_), do: ""

  defp load_settings(actor) do
    # We need to load the decrypted token for download.
    query =
      NetflowSettings
      |> Ash.Query.for_read(:get_singleton, %{}, actor: actor)
      |> Ash.Query.load([:ipinfo_api_key])

    case Ash.read_one(query, actor: actor) do
      {:ok, %NetflowSettings{} = s} ->
        s

      _ ->
        case NetflowSettings.create(%{}, actor: actor) do
          {:ok, %NetflowSettings{} = s} -> s
          _ -> nil
        end
    end
  end

  defp build_url(token) when is_binary(token) do
    "https://ipinfo.io/data/ipinfo_lite.mmdb?token=" <> URI.encode(token)
  end

  defp download_file(url, dest_path, timeout_ms) when is_binary(url) and is_binary(dest_path) do
    tmp = dest_path <> ".tmp"
    File.rm(tmp)

    req_opts = [
      receive_timeout: timeout_ms,
      retry: false,
      finch: [name: ServiceRadar.Finch]
    ]

    try do
      _resp = Req.get!(url, req_opts ++ [into: File.stream!(tmp)])

      File.rename!(tmp, dest_path)
      Logger.info("Ipinfo MMDB updated", file: dest_path)
      {:ok, dest_path}
    rescue
      e ->
        File.rm(tmp)
        {:error, e}
    end
  end

  defp file_present?(dir) when is_binary(dir) do
    File.regular?(Path.join(dir, @mmdb_filename))
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

  defp recently_updated?(path, seconds)
       when is_binary(path) and is_integer(seconds) and seconds > 0 do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        now = DateTime.to_unix(DateTime.utc_now(), :second)

        modified =
          mtime
          |> NaiveDateTime.from_erl!()
          |> DateTime.from_naive!("Etc/UTC")
          |> DateTime.to_unix(:second)

        now - modified < seconds - 600

      _ ->
        false
    end
  rescue
    _ -> false
  end
end
