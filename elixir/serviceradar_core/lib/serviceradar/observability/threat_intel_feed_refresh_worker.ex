defmodule ServiceRadar.Observability.ThreatIntelFeedRefreshWorker do
  @moduledoc """
  Refresh threat intel indicator feeds into `platform.threat_intel_indicators`.

  This is background-only work. Query-time SRQL MUST NOT fetch external data.
  Feed URLs are configured via `ServiceRadar.Observability.NetflowSettings`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.{NetflowSettings, ThreatIntelIndicator}
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]

  require Logger

  @default_timeout_ms 20_000
  @default_indicator_ttl_seconds 604_800
  @default_reschedule_seconds 86_400
  @default_max_indicators_per_feed 250_000

  @doc """
  Schedules the refresh job if not already scheduled.
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
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)

    indicator_ttl_seconds =
      Keyword.get(config, :indicator_ttl_seconds, @default_indicator_ttl_seconds)

    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    max_indicators_per_feed =
      Keyword.get(config, :max_indicators_per_feed, @default_max_indicators_per_feed)

    now = DateTime.utc_now()
    expires_at = DateTime.add(now, indicator_ttl_seconds, :second)
    actor = SystemActor.system(:threat_intel_refresh)

    settings =
      case NetflowSettings.get_settings(actor: actor) do
        {:ok, %NetflowSettings{} = s} -> s
        _ -> nil
      end

    urls =
      case settings do
        %NetflowSettings{threat_intel_enabled: true, threat_intel_feed_urls: urls}
        when is_list(urls) ->
          urls

        _ ->
          []
      end

    if urls == [] do
      ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 3_600)))
      :ok
    else
      Enum.each(urls, fn url ->
        refresh_feed(url, actor, now, expires_at, timeout_ms, max_indicators_per_feed)
      end)

      ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 3_600)))
      :ok
    end
  end

  defp refresh_feed(url, actor, now, expires_at, timeout_ms, max_indicators_per_feed)
       when is_binary(url) and is_integer(timeout_ms) do
    url = String.trim(url)

    if url == "" do
      :skip
    else
      do_refresh_feed(url, actor, now, expires_at, timeout_ms, max_indicators_per_feed)
    end
  end

  defp do_refresh_feed(url, actor, now, expires_at, timeout_ms, max_indicators_per_feed) do
    Logger.info("Threat intel feed refresh", url: url)

    with {:ok, body} <- download_feed(url, timeout_ms) do
      source = normalize_source(url)

      body
      |> parse_feed_indicators(max_indicators_per_feed)
      |> Enum.each(&upsert_indicator(&1, source, actor, now, expires_at))
    end

    :ok
  end

  defp download_feed(url, timeout_ms) do
    req_opts = [
      receive_timeout: timeout_ms,
      finch: ServiceRadar.Finch
    ]

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Threat intel feed download failed", url: url, status: status)
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("Threat intel feed download failed", url: url, error: inspect(reason))
        {:error, reason}
    end
  end

  defp parse_feed_indicators(body, max_indicators_per_feed)
       when is_binary(body) and is_integer(max_indicators_per_feed) do
    body
    |> String.split("\n")
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, ["#", ";", "//"])))
    |> Stream.map(&take_first_token/1)
    |> Stream.reject(&(&1 == "" or is_nil(&1)))
    |> Stream.map(&String.trim/1)
    |> Stream.filter(&valid_cidr?/1)
    |> Stream.take(max_indicators_per_feed)
    |> Enum.uniq()
  end

  defp upsert_indicator(indicator, source, actor, now, expires_at) do
    attrs = %{
      indicator: indicator,
      indicator_type: "cidr",
      source: source,
      first_seen_at: now,
      last_seen_at: now,
      expires_at: expires_at
    }

    changeset = Ash.Changeset.for_create(ThreatIntelIndicator, :upsert, attrs)

    case Ash.create(changeset, actor: actor) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Threat intel upsert failed",
          indicator: indicator,
          source: source,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp take_first_token(line) when is_binary(line) do
    line
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(",")
  end

  defp valid_cidr?(value) when is_binary(value) do
    case ServiceRadar.Types.Cidr.cast_input(value, []) do
      {:ok, normalized} when is_binary(normalized) and normalized != "" -> true
      _ -> false
    end
  end

  defp normalize_source(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> url
    end
  end
end
