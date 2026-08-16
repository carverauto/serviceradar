defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker do
  @moduledoc """
  Self-scheduling Oban worker that ingests one advisory feed (design D1).

  One job kind per feed, keyed by the `feed` arg:

    * `"cisa-kev"`     — CISA KEV JSON, ~hourly enrichment
    * `"vulncheck-kev"`— VulnCheck KEV backup (CISA-KEV-shaped array), 6h
    * `"nist-nvd2"`    — VulnCheck nist-nvd2 backup (full NVD CPE dataset), daily,
                          gated by both the feature flag and a sub-gate. Resumes
                          an in-progress generation after a core restart.
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

  @impl true
  # farm01 nist-nvd2 inserted ~360k advisories / 2.5M coordinates in 30 minutes
  # and still had shards left. 60 minutes leaves headroom for a cold PVC.
  def timeout(%Oban.Job{args: %{"feed" => "nist-nvd2"}}), do: 3_600_000
  def timeout(_job), do: 180_000

  # Must exceed the longest worker timeout. 15 minutes was marking a live
  # nist-nvd2 run stale because already_scheduled?/1 could not see the job
  # (it queried "Elixir.ServiceRadar..." while Oban stores the bare module).
  @stale_running_seconds 75 * 60
  @worker_name inspect(__MODULE__)

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
      reclaim_dead_node_jobs()
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
        where: j.worker == ^@worker_name,
        where: j.state in ["available", "scheduled", "retryable", "executing"],
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
        where: j.worker == ^@worker_name,
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

    mark_status(
      feed,
      %{last_status: "running", last_attempt_at: started, last_error: nil, last_message: nil},
      actor
    )

    try do
      case do_run(feed) do
        {:ok, result} ->
          Logger.info("advisory_feeds: #{feed} loaded", result: inspect(result))

          mark_status(
            feed,
            %{
              last_status: "success",
              last_success_at: DateTime.utc_now(),
              last_message:
                "loaded #{result.advisories_upserted} advisories" <>
                  skip_suffix(result),
              last_error: nil,
              metadata: %{
                "advisories" => result.advisories_upserted,
                "coordinates" => result.coordinates_upserted,
                "skipped" => Map.get(result, :advisories_skipped, 0),
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
  def orphan_executing_job?(job, live_owners, now \\ DateTime.utc_now())

  def orphan_executing_job?(%{state: "executing", args: args} = job, live_owners, now) do
    owner = job |> Map.get(:attempted_by) |> List.wrap() |> List.first()
    feed = args["feed"] || args[:feed]
    age = job_age_seconds(job, now)

    cond do
      is_binary(owner) and owner not in live_owners -> true
      is_integer(age) and age >= reclaim_after_seconds(feed) -> true
      true -> false
    end
  end

  def orphan_executing_job?(_job, _live_owners, _now), do: false

  @doc false
  def live_owner_names(nodes \\ [Node.self() | Node.list()]) do
    MapSet.new(nodes, &to_string/1)
  end

  defp reclaim_dead_node_jobs(now \\ DateTime.utc_now()) do
    live_owners = live_owner_names()
    actor = SystemActor.system(:advisory_feed_worker)

    Enum.each(@feeds, fn feed ->
      feed
      |> executing_jobs()
      |> Enum.filter(&orphan_executing_job?(&1, live_owners, now))
      |> Enum.each(fn job ->
        owner = job |> Map.get(:attempted_by) |> List.wrap() |> List.first()
        _ = discard_orphan_job(job, now)

        Logger.warning("advisory_feeds: discarded orphaned #{feed} job #{job.id}",
          owner: owner
        )

        mark_status(
          feed,
          %{
            last_status: "error",
            last_failure_at: now,
            last_error: "orphaned executing job; owner #{owner} is gone"
          },
          actor
        )
      end)
    end)
  end

  defp executing_jobs(feed) do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^@worker_name,
        where: j.state == "executing",
        where: fragment("?->>'feed' = ?", j.args, ^feed)
      )

    ServiceRadar.Repo.all(query, prefix: ObanSupport.prefix())
  rescue
    _ -> []
  end

  defp discard_orphan_job(%Oban.Job{} = job, now) do
    discarded_at =
      case now do
        %DateTime{} = dt -> DateTime.to_naive(dt)
        other -> other
      end

    job
    |> Ecto.Changeset.change(state: "discarded", discarded_at: discarded_at)
    |> ServiceRadar.Repo.update(prefix: ObanSupport.prefix())
  rescue
    error -> {:error, error}
  end

  defp job_age_seconds(%{attempted_at: %DateTime{} = attempted_at}, %DateTime{} = now) do
    DateTime.diff(now, attempted_at, :second)
  end

  defp job_age_seconds(%{attempted_at: %NaiveDateTime{} = attempted_at}, %DateTime{} = now) do
    NaiveDateTime.diff(DateTime.to_naive(now), attempted_at, :second)
  end

  defp job_age_seconds(_job, _now), do: 0

  # Just past the Oban timeout so a live run is not discarded, but a
  # producer that died without releasing `executing` cannot pin unique.
  defp reclaim_after_seconds("nist-nvd2"), do: 65 * 60
  defp reclaim_after_seconds(_feed), do: 5 * 60

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

    with {:ok, acquired} <- Acquisition.acquire_cisa(url, run_id) do
      with_run_cleanup(acquired, fn ->
        parse_and_load(acquired, "cisa", "cisa-kev", &parse_kev/1)
      end)
    end
  end

  defp do_run("vulncheck-kev") do
    with {:ok, token} <- Config.vulncheck_token(),
         {:ok, acquired} <-
           Acquisition.acquire_vulncheck("vulncheck-kev", token, run_id()) do
      with_run_cleanup(acquired, fn ->
        parse_and_load(acquired, "vulncheck", "vulncheck-kev", &parse_kev/1)
      end)
    end
  end

  defp do_run("nist-nvd2") do
    if Staging.volume_available?() do
      with {:ok, token} <- Config.vulncheck_token(),
           {:ok, index} <- Acquisition.resolve_backup_index("nist-nvd2", token),
           {:ok, acquired, resume} <- reuse_or_acquire_nvd(token, index) do
        result = parse_and_load_nvd(acquired, resume)

        if match?({:ok, _}, result) do
          Staging.cleanup_run(acquired.run_dir)
        end

        result
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

  # Failed nist-nvd2 runs used to keep the 900 MB extract. On demo that piled
  # up to 255 GiB and evicted the node. Always drop the run dir.
  defp with_run_cleanup(acquired, fun) do
    fun.()
  after
    Staging.cleanup_run(acquired.run_dir)
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

  defp parse_and_load_nvd(acquired, resume) do
    provider = "nvd"
    feed_key = "nist-nvd2"

    generation =
      case resume.generation do
        :next -> Loader.next_generation(provider, feed_key)
        n when is_integer(n) -> n
      end

    Logger.info("advisory_feeds: nist-nvd2 loading generation #{generation}",
      after_shard: resume.after_shard,
      extract_dir: acquired.extracted_dir
    )

    existing_modified = Loader.existing_modified_at(provider, feed_key)

    result =
      acquired.extracted_dir
      |> StreamReader.nvd_shard_paths(after: resume.after_shard)
      |> Enum.reduce(
        %{
          advisories_upserted: 0,
          coordinates_upserted: 0,
          advisories_skipped: 0,
          generation: generation
        },
        fn shard_path, acc ->
          shard = Path.basename(shard_path)

          shard_result =
            shard_path
            |> StreamReader.stream_nvd_shard()
            |> Stream.flat_map(fn {:ok, record} ->
              case Parsers.Nvd.parse_record(record, provider: provider, feed_key: feed_key) do
                {:ok, mapped} -> [mapped]
                :skip -> []
              end
            end)
            |> Loader.load_stream(
              provider: provider,
              feed_key: feed_key,
              generation: generation,
              existing_modified: existing_modified
            )

          persist_nvd_checkpoint(%{
            "generation" => generation,
            "extract_dir" => acquired.extracted_dir,
            "run_dir" => acquired.run_dir,
            "sha256" => resume.sha256,
            "last_completed_shard" => shard
          })

          %{
            acc
            | advisories_upserted: acc.advisories_upserted + shard_result.advisories_upserted,
              coordinates_upserted: acc.coordinates_upserted + shard_result.coordinates_upserted,
              advisories_skipped: acc.advisories_skipped + shard_result.advisories_skipped
          }
        end
      )

    Loader.finalize(provider, feed_key, generation)
    clear_nvd_checkpoint(result)
    {:ok, result}
  end

  @doc false
  def resume_plan(opts) when is_list(opts) do
    resume_plan(
      Keyword.get(opts, :checkpoint),
      Keyword.get(opts, :extract),
      Keyword.get(opts, :in_progress_generation),
      Keyword.get(opts, :sha256)
    )
  end

  def resume_plan(checkpoint, extract, in_progress_generation, sha256) do
    extract_dir = extract_dir(extract, checkpoint)
    sha_ok? = sha_matches?(checkpoint, sha256)

    cond do
      existing_dir?(extract_dir) and sha_ok? and checkpoint_generation(checkpoint) ->
        {:reuse,
         %{
           generation: checkpoint_generation(checkpoint),
           after_shard: checkpoint_shard(checkpoint),
           extract: extract || extract_from_checkpoint(checkpoint),
           sha256: sha256
         }}

      existing_dir?(extract_dir) and is_integer(in_progress_generation) ->
        {:reuse,
         %{
           generation: in_progress_generation,
           after_shard: checkpoint_shard(checkpoint),
           extract: extract || extract_from_checkpoint(checkpoint),
           sha256: sha256
         }}

      existing_dir?(extract_dir) ->
        {:reuse,
         %{
           generation: :next,
           after_shard: nil,
           extract: extract || extract_from_checkpoint(checkpoint),
           sha256: sha256
         }}

      true ->
        :download
    end
  end

  defp reuse_or_acquire_nvd(token, index) when is_map(index) do
    sha256 = index["sha256"]
    checkpoint = nvd_checkpoint()
    extract = Staging.latest_extract("nist-nvd2")
    in_progress = Loader.in_progress_generation("nvd", "nist-nvd2")

    case resume_plan(checkpoint, extract, in_progress, sha256) do
      {:reuse, resume} ->
        Logger.info("advisory_feeds: nist-nvd2 resuming extract",
          generation: resume.generation,
          after_shard: resume.after_shard
        )

        {:ok, acquired_from_extract(resume.extract, sha256), resume}

      :download ->
        with {:ok, acquired} <- Acquisition.acquire_vulncheck("nist-nvd2", token, run_id()) do
          {:ok, acquired, %{generation: :next, after_shard: nil, sha256: sha256, extract: nil}}
        end
    end
  end

  defp acquired_from_extract(extract, sha256) when is_map(extract) do
    %{
      extracted_dir: extract.extracted_dir || extract["extract_dir"],
      run_dir: extract.run_dir || extract["run_dir"],
      download_path: Map.get(extract, :download_path) || Map.get(extract, "download_path"),
      format: :json_gz_shards,
      source_url: nil,
      sha256: sha256
    }
  end

  defp nvd_checkpoint do
    actor = SystemActor.system(:advisory_feed_worker)

    case read_definition("nvd", "nist-nvd2", actor) do
      {:ok, %{metadata: metadata}} when is_map(metadata) -> metadata["nvd_checkpoint"]
      _ -> nil
    end
  end

  defp persist_nvd_checkpoint(checkpoint) when is_map(checkpoint) do
    actor = SystemActor.system(:advisory_feed_worker)

    case read_definition("nvd", "nist-nvd2", actor) do
      {:ok, %{metadata: metadata}} ->
        mark_status(
          "nist-nvd2",
          %{metadata: Map.put(metadata || %{}, "nvd_checkpoint", checkpoint)},
          actor
        )

      _ ->
        :ok
    end
  end

  defp clear_nvd_checkpoint(result) when is_map(result) do
    actor = SystemActor.system(:advisory_feed_worker)

    case read_definition("nvd", "nist-nvd2", actor) do
      {:ok, %{metadata: metadata}} ->
        mark_status(
          "nist-nvd2",
          %{
            metadata:
              (metadata || %{})
              |> Map.delete("nvd_checkpoint")
              |> Map.merge(%{
                "advisories" => result.advisories_upserted,
                "coordinates" => result.coordinates_upserted,
                "skipped" => Map.get(result, :advisories_skipped, 0),
                "generation" => result.generation
              })
          },
          actor
        )

      _ ->
        :ok
    end
  end

  defp extract_dir(extract, checkpoint) do
    cond do
      is_map(extract) -> extract.extracted_dir || extract[:extracted_dir]
      is_map(checkpoint) -> checkpoint["extract_dir"]
      true -> nil
    end
  end

  defp extract_from_checkpoint(checkpoint) when is_map(checkpoint) do
    %{
      extracted_dir: checkpoint["extract_dir"],
      run_dir: checkpoint["run_dir"],
      download_path: nil
    }
  end

  defp extract_from_checkpoint(_), do: nil

  defp existing_dir?(dir) when is_binary(dir), do: File.dir?(dir)
  defp existing_dir?(_), do: false

  defp sha_matches?(_checkpoint, sha256) when sha256 in [nil, ""], do: true
  defp sha_matches?(nil, _sha256), do: true

  defp sha_matches?(checkpoint, sha256) when is_map(checkpoint) do
    stored = checkpoint["sha256"]
    stored in [nil, "", sha256]
  end

  defp sha_matches?(_checkpoint, _sha256), do: true

  defp checkpoint_generation(%{"generation" => n}) when is_integer(n), do: n
  defp checkpoint_generation(_), do: nil

  defp checkpoint_shard(%{"last_completed_shard" => shard}) when is_binary(shard), do: shard
  defp checkpoint_shard(_), do: nil

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

  defp skip_suffix(%{advisories_skipped: skipped}) when is_integer(skipped) and skipped > 0,
    do: " (#{skipped} unchanged)"

  defp skip_suffix(_result), do: ""

  defp run_id do
    DateTime.utc_now()
    |> DateTime.to_unix(:millisecond)
    |> Integer.to_string()
  end
end
