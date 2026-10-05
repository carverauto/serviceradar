defmodule ServiceRadar.Observability.ThreatIntelFeedRefreshWorker do
  @moduledoc """
  Refresh threat intel indicator feeds into `platform.threat_intel_indicators`.

  This is background-only work. Query-time SRQL MUST NOT fetch external data.
  Feed URLs are configured via `ServiceRadar.Observability.NetflowSettings`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Exclude :executing so the self-reschedule in perform/1 isn't deduped
    # against the still-running job (double-seed guarded by check_existing_job).
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.HTTP.EgressClient
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.OutboundFeedPolicy
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.PrefixTags.ThreatIntelSource
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_timeout_ms 20_000
  @default_indicator_ttl_seconds 604_800
  @default_reschedule_seconds 86_400
  @default_max_indicators_per_feed 250_000
  @upsert_batch_size 1_000

  @doc """
  Schedules the refresh job if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(__MODULE__),
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

      # One trie rebuild per refresh cycle, not once per feed URL.
      _ = maybe_reload_ti_trie()

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
    Logger.info("Threat intel feed refresh", url: OutboundFeedPolicy.redact_url(url))

    with {:ok, body} <- download_feed(url, timeout_ms) do
      ingest_feed_body(body, normalize_source(url),
        actor: actor,
        now: now,
        expires_at: expires_at,
        max_indicators: max_indicators_per_feed
      )
    end

    :ok
  end

  @doc false
  # The persistence half of a feed refresh, separate from the download so it can
  # be exercised without an outbound fetch. Returns the number of indicators the
  # feed contributed.
  @spec ingest_feed_body(binary(), String.t(), keyword()) :: non_neg_integer()
  def ingest_feed_body(body, source, opts) when is_binary(body) and is_binary(source) do
    actor = Keyword.fetch!(opts, :actor)
    now = Keyword.fetch!(opts, :now)
    expires_at = Keyword.fetch!(opts, :expires_at)
    max_indicators = Keyword.get(opts, :max_indicators, @default_max_indicators_per_feed)

    indicators = parse_feed_indicators(body, max_indicators)

    indicators
    |> Enum.map(&indicator_attrs(&1, source, now, expires_at))
    |> upsert_indicators(source, actor)

    length(indicators)
  end

  defp maybe_reload_ti_trie do
    if Code.ensure_loaded?(ThreatIntelSource) do
      case ThreatIntelSource.reload() do
        {:ok, %{row_count: count}} ->
          Logger.info("Prefix-tag ti trie refreshed after threat feed", rows: count)
          :ok

        {:error, reason} ->
          Logger.debug("Prefix-tag ti trie reload skipped", reason: inspect(reason))
          :ok
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.debug("Prefix-tag ti trie reload failed", error: Exception.message(e))
      :ok
  end

  # EgressClient, not the shared Finch pool: the pool cannot tunnel through
  # SERVICERADAR_EGRESS_PROXY.
  defp download_feed(url, timeout_ms) do
    with :ok <- OutboundFeedPolicy.validate(url),
         {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           EgressClient.fetch_body(url, receive_timeout: timeout_ms) do
      {:ok, body}
    else
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Threat intel feed download failed",
          url: OutboundFeedPolicy.redact_url(url),
          status: status
        )

        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("Threat intel feed download failed",
          url: url,
          error: OutboundFeedPolicy.format_reason(reason)
        )

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
    |> Stream.map(&normalize_cidr/1)
    |> Stream.reject(&is_nil/1)
    |> Stream.take(max_indicators_per_feed)
    # Deduplicated on the stored form: one batched upsert may not name the same
    # (source, indicator) twice, and "192.0.2.1" and "192.0.2.1/32" are one row.
    |> Enum.uniq()
  end

  defp indicator_attrs(indicator, source, now, expires_at) do
    %{
      indicator: indicator,
      indicator_type: "cidr",
      source: source,
      first_seen_at: now,
      last_seen_at: now,
      expires_at: expires_at
    }
  end

  # One INSERT ... ON CONFLICT per batch through the same :upsert action the
  # per-indicator path used, so the conflict target and updated fields are
  # unchanged. A failed batch is logged and the remaining batches still run.
  defp upsert_indicators([], _source, _actor), do: :ok

  defp upsert_indicators(attrs, source, actor) do
    result =
      Ash.bulk_create(attrs, ThreatIntelIndicator, :upsert,
        actor: actor,
        batch_size: @upsert_batch_size,
        transaction: :batch,
        return_records?: false,
        return_errors?: true,
        stop_on_error?: false
      )

    case result do
      %Ash.BulkResult{error_count: 0} ->
        :ok

      %Ash.BulkResult{error_count: count, errors: errors} ->
        Logger.warning("Threat intel upsert failed",
          source: source,
          failed: count,
          reason: inspect(Enum.take(List.wrap(errors), 3))
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

  defp normalize_cidr(value) when is_binary(value) do
    case ServiceRadar.Types.Cidr.cast_input(value, []) do
      {:ok, normalized} when is_binary(normalized) and normalized != "" -> normalized
      _ -> nil
    end
  end

  defp normalize_source(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> url
    end
  end
end
