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
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.GeoIP
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger
  import Ecto.Query, only: [from: 2]

  @default_dir "/var/lib/serviceradar/geoip"
  @default_timeout_ms 20_000
  @default_reschedule_seconds 86_400
  @default_failure_reschedule_seconds 6 * 3600
  @mmdb_filename "ipinfo_lite.mmdb"

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

    File.mkdir_p!(dir)

    actor = SystemActor.system(:ipinfo_mmdb_download)
    settings = load_settings(actor)
    force? = Map.get(job.args || %{}, "force") == true

    token = download_token(settings)
    dest = Path.join(dir, @mmdb_filename)

    cond do
      token == "" ->
        Logger.debug("Ipinfo MMDB download skipped (missing token or disabled)")
        schedule_next(reschedule_seconds)

      not force? and recently_updated?(dest, reschedule_seconds) ->
        schedule_next(reschedule_seconds)

      true ->
        url = build_url(token)

        case download_file(url, dest, timeout_ms) do
          {:ok, _} ->
            # Ensure Geolix sees newly downloaded databases without requiring a pod restart.
            _ = GeoIP.reload()
            schedule_next(reschedule_seconds)

          {:error, reason} ->
            Logger.warning("Ipinfo MMDB download failed", error: inspect(reason))
            schedule_next(failure_reschedule_seconds)
        end
    end
  end

  defp schedule_next(seconds) when is_integer(seconds) do
    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(seconds, 3_600)))
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
      finch: ServiceRadar.Finch
    ]

    try do
      _resp =
        url
        |> Req.get!(req_opts ++ [into: File.stream!(tmp)])

      File.rename!(tmp, dest_path)
      Logger.info("Ipinfo MMDB updated", file: dest_path)
      {:ok, dest_path}
    rescue
      e ->
        File.rm(tmp)
        {:error, e}
    end
  end

  defp recently_updated?(path, seconds)
       when is_binary(path) and is_integer(seconds) and seconds > 0 do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        now = DateTime.utc_now() |> DateTime.to_unix(:second)

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
