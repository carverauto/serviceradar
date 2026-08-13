defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker do
  @moduledoc """
  Self-scheduling Oban worker that ingests one advisory feed (design D1).

  One job kind per feed, keyed by the `feed` arg:

    * `"cisa-kev"`     — CISA KEV JSON, ~hourly enrichment
    * `"vulncheck-kev"`— VulnCheck KEV backup (CISA-KEV-shaped array), 6h
    * `"nist-nvd2"`    — VulnCheck nist-nvd2 backup (full NVD CPE dataset), 6h,
                          gated by both the feature flag and a sub-gate
    * `"nvd-api"`      — NVD CVE 2.0 REST fallback (stub; not wired in this slice
                          and intentionally NOT in `@feeds`, so it is never
                          scheduled — `do_run/1` keeps the stub for future wiring)

  The whole lifecycle — acquire → stage → extract → stream-parse → bulk-load →
  generation swap — runs in core with `SystemActor`. Single-flight is enforced by
  Oban `unique` (one in-flight job per feed) plus the per-run staging dir.

  Feature flag `advisory_feeds_core_enabled` gates all feeds; `nist-nvd2` is
  additionally sub-gated so KEV enrichment can run even when the large NVD load
  is disabled or the PVC is missing (fail-closed).
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:feed],
      states: :incomplete
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.AdvisoryFeeds.Acquisition
  alias ServiceRadar.Inventory.AdvisoryFeeds.Config
  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader
  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers
  alias ServiceRadar.Inventory.AdvisoryFeeds.Staging
  alias ServiceRadar.Inventory.AdvisoryFeeds.StreamReader
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @impl Oban.Worker
  def timeout(_job), do: 180_000

  @stale_running_seconds 15 * 60

  # NOTE: "nvd-api" is intentionally excluded — `do_run("nvd-api")` is an
  # unimplemented stub, so scheduling it only produces error+reschedule noise.
  # Add it back here once the NVD CVE 2.0 REST fallback is wired.
  @feeds ~w(cisa-kev vulncheck-kev nist-nvd2)

  @doc "All feed keys this worker can run."
  @spec feeds() :: [String.t()]
  def feeds, do: @feeds

  @doc "Enqueue all enabled feeds that are not already in flight."
  @spec ensure_scheduled() :: {:ok, :scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      _ = Staging.reap_orphans()
      reconcile_stale_runs()

      if Config.enabled?() do
        Enum.each(@feeds, &maybe_enqueue/1)
      end

      {:ok, :scheduled}
    else
      {:error, :oban_unavailable}
    end
  end

  @doc "Enqueue a single feed now (operator \"Run now\")."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(feed) when feed in @feeds do
    _ = cancel_incomplete(feed)
    %{feed: feed} |> new() |> ObanSupport.safe_insert()
  end

  def enqueue(_feed), do: {:error, :unknown_feed}

  defp maybe_enqueue(feed) do
    cond do
      not Config.feed_enabled?(feed) ->
        :ok

      already_scheduled?(feed) ->
        :ok

      true ->
        _ = ObanSupport.safe_insert(new(%{feed: feed}, schedule_in: 5))
        :ok
    end
  end

  defp mark_disabled(feed) do
    actor = SystemActor.system(:advisory_feed_worker)

    mark_status(
      feed,
      %{
        last_status: "error",
        last_failure_at: DateTime.utc_now(),
        last_error:
          "advisory feed ingestion is disabled on this deployment (enable core.advisoryFeeds)"
      },
      actor
    )
  end

  defp cancel_incomplete(feed) do
    import Ecto.Query

    ServiceRadar.Repo.delete_all(
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("?->>'feed' = ?", j.args, ^feed)
      ),
      prefix: ObanSupport.prefix()
    )
  rescue
    _ -> {0, nil}
  end

  defp already_scheduled?(feed) do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("?->>'feed' = ?", j.args, ^feed),
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  rescue
    _ -> false
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"feed" => feed}}) when feed in @feeds do
    cond do
      not Config.enabled?() ->
        Logger.info("advisory_feeds: disabled, skipping #{feed}")
        mark_disabled(feed)
        :ok

      not Config.feed_enabled?(feed) ->
        Logger.info("advisory_feeds: #{feed} disabled, skipping")
        :ok

      feed == "nist-nvd2" and not Config.nist_nvd2_enabled?() ->
        Logger.info("advisory_feeds: nist-nvd2 sub-gate off, skipping")
        schedule_next(feed)
        :ok

      true ->
        run_feed(feed)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("advisory_feeds: unknown feed args #{inspect(args)}")
    {:error, :unknown_feed}
  end

  defp run_feed(feed) do
    actor = SystemActor.system(:advisory_feed_worker)
    started = DateTime.utc_now()
    mark_status(feed, %{last_status: "running", last_attempt_at: started}, actor)

    try do
      case do_run(feed) do
        {:ok, result} ->
          Logger.info("advisory_feeds: #{feed} loaded", result: inspect(result))

          mark_status(
            feed,
            %{
              last_status: "success",
              last_success_at: DateTime.utc_now(),
              last_message: "loaded #{result.advisories_upserted} advisories",
              last_error: nil,
              metadata: %{
                "advisories" => result.advisories_upserted,
                "coordinates" => result.coordinates_upserted,
                "generation" => result.generation
              }
            },
            actor
          )

          schedule_next(feed)
          :ok

        {:error, reason} ->
          fail_feed(feed, reason, actor)
      end
    rescue
      exception ->
        fail_feed(feed, exception, actor)
        reraise exception, __STACKTRACE__
    end
  end

  defp fail_feed(feed, reason, actor) do
    Logger.warning("advisory_feeds: #{feed} failed: #{inspect(reason)}",
      reason: inspect(reason)
    )

    mark_status(
      feed,
      %{
        last_status: "error",
        last_failure_at: DateTime.utc_now(),
        last_error: inspect(reason)
      },
      actor
    )

    schedule_next(feed)
    {:error, reason}
  end

  @doc false
  def reconcile_stale_runs(now \\ DateTime.utc_now()) do
    actor = SystemActor.system(:advisory_feed_worker)

    Enum.each(@feeds, fn feed ->
      {provider, feed_key} = provider_feed(feed)

      case read_definition(provider, feed_key, actor) do
        {:ok, %{last_status: "running", last_attempt_at: %DateTime{} = attempted_at} = definition} ->
          if DateTime.diff(now, attempted_at, :second) >= @stale_running_seconds and
               not already_scheduled?(feed) do
            mark_status(
              feed,
              %{
                last_status: "error",
                last_failure_at: now,
                last_error: definition.last_error || "stale running status; no in-flight job"
              },
              actor
            )
          end

        _ ->
          :ok
      end
    end)

    :ok
  end

  defp read_definition(provider, feed_key, actor) do
    VulnerabilityFeedDefinition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(provider == ^provider and feed_key == ^feed_key)
    |> Ash.read_one(actor: actor)
  end

  # --- per-feed pipelines ---------------------------------------------------

  defp do_run("cisa-kev") do
    run_id = run_id()
    url = Config.cisa_kev_url()

    with {:ok, acquired} <- Acquisition.acquire_cisa(url, run_id),
         {:ok, result} <- parse_and_load(acquired, "cisa", "cisa-kev", &parse_kev/1) do
      Staging.cleanup_run(acquired.run_dir)
      {:ok, result}
    end
  end

  defp do_run("vulncheck-kev") do
    with {:ok, token} <- Config.vulncheck_token(),
         {:ok, acquired} <-
           Acquisition.acquire_vulncheck("vulncheck-kev", token, run_id()),
         {:ok, result} <- parse_and_load(acquired, "vulncheck", "vulncheck-kev", &parse_kev/1) do
      Staging.cleanup_run(acquired.run_dir)
      {:ok, result}
    end
  end

  defp do_run("nist-nvd2") do
    if Staging.volume_available?() do
      with {:ok, token} <- Config.vulncheck_token(),
           {:ok, acquired} <- Acquisition.acquire_vulncheck("nist-nvd2", token, run_id()),
           {:ok, result} <- parse_and_load_nvd(acquired) do
        Staging.cleanup_run(acquired.run_dir)
        {:ok, result}
      end
    else
      Logger.warning(
        "advisory_feeds: staging volume unavailable, skipping nist-nvd2 (fail closed)"
      )

      {:error, :staging_volume_unavailable}
    end
  end

  defp do_run("nvd-api") do
    # NVD CVE 2.0 REST fallback is intentionally a stub in this slice (paginated,
    # rate-limited). VulnCheck nist-nvd2 is the primary CPE source.
    {:error, :nvd_api_not_implemented}
  end

  defp parse_and_load(acquired, provider, feed_key, parse_fun) do
    json_path = single_json(acquired.extracted_dir)

    records =
      json_path
      |> StreamReader.stream_json_file(records_key: records_key(feed_key))
      |> Stream.flat_map(fn {:ok, record} -> parse_fun.({record, provider, feed_key}) end)

    generation = Loader.next_generation(provider, feed_key)

    result =
      Loader.load_stream(records, provider: provider, feed_key: feed_key, generation: generation)

    Loader.finalize(provider, feed_key, generation)
    {:ok, result}
  end

  defp parse_and_load_nvd(acquired) do
    provider = "nvd"
    feed_key = "nist-nvd2"

    records =
      acquired.extracted_dir
      |> StreamReader.stream_nvd_shards()
      |> Stream.flat_map(fn {:ok, record} ->
        case Parsers.Nvd.parse_record(record, provider: provider, feed_key: feed_key) do
          {:ok, mapped} -> [mapped]
          :skip -> []
        end
      end)

    generation = Loader.next_generation(provider, feed_key)

    result =
      Loader.load_stream(records, provider: provider, feed_key: feed_key, generation: generation)

    Loader.finalize(provider, feed_key, generation)
    {:ok, result}
  end

  defp parse_kev({record, provider, feed_key}) do
    case Parsers.Kev.parse_record(record, provider: provider, feed_key: feed_key) do
      {:ok, mapped} -> [mapped]
      :skip -> []
    end
  end

  defp records_key("cisa-kev"), do: "vulnerabilities"
  defp records_key("vulncheck-kev"), do: :array
  defp records_key(_), do: "vulnerabilities"

  defp single_json(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.sort()
    |> List.first()
    |> case do
      nil -> raise "no .json file extracted in #{dir}"
      name -> Path.join(dir, name)
    end
  end

  defp mark_status(feed, attrs, actor) do
    {provider, feed_key} = provider_feed(feed)

    case VulnerabilityFeedDefinition
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(provider == ^provider and feed_key == ^feed_key)
         |> Ash.read_one(actor: actor) do
      {:ok, %VulnerabilityFeedDefinition{} = def} ->
        def
        |> Ash.Changeset.for_update(:update_status, attrs, actor: actor)
        |> Ash.update(actor: actor)

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.debug("advisory_feeds: status update skipped: #{inspect(error)}")
      :ok
  end

  defp provider_feed("cisa-kev"), do: {"cisa", "cisa-kev"}
  defp provider_feed("vulncheck-kev"), do: {"vulncheck", "vulncheck-kev"}
  defp provider_feed("nist-nvd2"), do: {"nvd", "nist-nvd2"}
  defp provider_feed("nvd-api"), do: {"nvd", "nvd-api"}

  defp schedule_next(feed) do
    if Config.feed_enabled?(feed) do
      seconds = Config.refresh_seconds(feed)
      _ = ObanSupport.safe_insert(new(%{feed: feed}, schedule_in: seconds))
    end

    :ok
  end

  defp run_id do
    DateTime.utc_now()
    |> DateTime.to_unix(:millisecond)
    |> Integer.to_string()
  end
end
