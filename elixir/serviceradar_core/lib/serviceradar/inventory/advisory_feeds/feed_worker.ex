defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker do
  @moduledoc """
  Self-scheduling Oban worker that ingests one advisory feed (design D1).

  One job kind per feed, keyed by the `feed` arg:

    * `"cisa-kev"`     — CISA KEV JSON, ~hourly enrichment
    * `"vulncheck-kev"`— VulnCheck KEV backup (CISA-KEV-shaped array), 6h
    * `"nist-nvd2"`    — VulnCheck nist-nvd2 backup (full NVD CPE dataset), 6h,
                          gated by both the feature flag and a sub-gate
    * `"ubuntu-osv-vex"` — Canonical's atomic Ubuntu OSV + OpenVEX tree, 6h
    * `"nvd-api"`      — NVD CVE 2.0 REST fallback (stub; not wired in this slice
                          and intentionally NOT in `@feeds`, so it is never
                          scheduled — `do_run/2` keeps the stub for future wiring)

  The whole lifecycle — acquire → stage → extract → stream-parse → bulk-load →
  generation swap — runs in core with `SystemActor`. Single-flight is enforced by
  Oban `unique` (one in-flight job per feed) plus the per-run staging dir.

  Feature flag `advisory_feeds_core_enabled` gates all feeds; `nist-nvd2` is
  additionally sub-gated so KEV enrichment can run even when the large NVD load
  is disabled or the PVC is missing (fail-closed).
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 4,
    unique: [
      period: :infinity,
      keys: [:feed],
      states: :incomplete
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.AdvisoryFeeds.Acquisition
  alias ServiceRadar.Inventory.AdvisoryFeeds.Config
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedRegistry
  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader
  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers
  alias ServiceRadar.Inventory.AdvisoryFeeds.Staging
  alias ServiceRadar.Inventory.AdvisoryFeeds.StreamReader
  alias ServiceRadar.Inventory.AdvisoryFeeds.UbuntuAdapter
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  # Retry spacing, in seconds, for attempts 2..4.
  #
  # Oban's default backoff put all three attempts of a nist-nvd2 run inside 65
  # seconds (2026-08-22: 03:08:28, 03:09:12, 03:09:33). Every one of them sampled
  # the same one-minute window of upstream health, so a brief VulnCheck timeout
  # discarded the job and the feed then sat idle until the next 6-hour tick.
  #
  # These feeds refresh every 6 hours. Retrying three times inside a minute buys
  # nothing; spreading the same three retries across ~42 minutes rides out a
  # transient upstream problem and still finishes inside one cycle, even if
  # every attempt burns the longest feed timeout first.
  @backoff_seconds [120, 600, 1800]

  @impl true
  def backoff(%Oban.Job{attempt: attempt}) do
    base = Enum.at(@backoff_seconds, attempt - 1, List.last(@backoff_seconds))

    # +/-10% jitter: three feeds share one upstream, and a shared outage would
    # otherwise have them all retry in lockstep.
    spread = max(div(base, 10), 1)
    base - spread + :rand.uniform(2 * spread)
  end

  @impl true
  # farm01 nist-nvd2 inserted ~360k advisories / 2.5M coordinates in 30 minutes
  # and still had shards left. 60 minutes leaves headroom for a cold PVC.
  def timeout(%Oban.Job{args: %{"feed" => "nist-nvd2"}}), do: 3_600_000

  # Preparing and projecting the bounded official Ubuntu archives takes close
  # to an hour on remote runners. Keep a finite whole-job limit with headroom.
  def timeout(%Oban.Job{args: %{"feed" => "ubuntu-osv-vex"}}), do: 4_500_000

  def timeout(_job), do: 180_000

  # Must exceed the longest worker timeout. 15 minutes was marking a live
  # nist-nvd2 run stale because already_scheduled?/1 could not see the job
  # (it queried "Elixir.ServiceRadar..." while Oban stores the bare module).
  @stale_running_seconds 90 * 60

  # Grace before a node-less job is considered orphaned. Short, because node
  # liveness is already the decisive signal; this only covers a brief netsplit.
  @orphan_grace_seconds 5 * 60
  @rpc_timeout_ms 5_000
  @worker_name inspect(__MODULE__)

  # NOTE: "nvd-api" is intentionally excluded — `do_run("nvd-api")` is an
  # unimplemented stub, so scheduling it only produces error+reschedule noise.
  # Add it back here once the NVD CVE 2.0 REST fallback is wired.
  @feeds ~w(cisa-kev vulncheck-kev nist-nvd2 ubuntu-osv-vex)
  @retained_count_feeds ~w(cisa-kev vulncheck-kev nist-nvd2)
  @retained_count_percent 90

  @doc "All feed keys this worker can run."
  @spec feeds() :: [String.t()]
  def feeds, do: @feeds

  @doc false
  def snapshot_minimum(feed_key, prior_count, absolute_minimum, opts \\ [])
      when is_binary(feed_key) and is_integer(prior_count) and prior_count >= 0 and
             is_integer(absolute_minimum) and
             absolute_minimum > 0 and is_list(opts) do
    if feed_key in @retained_count_feeds do
      retained_minimum = div(prior_count * @retained_count_percent + 99, 100)
      default_minimum = max(absolute_minimum, retained_minimum)

      if Keyword.get(opts, :accept_snapshot_contraction) == true do
        {absolute_minimum,
         %{
           "policy" => "operator_approved_contraction",
           "prior_count" => prior_count,
           "minimum_count" => absolute_minimum,
           "default_minimum_count" => default_minimum,
           "retained_percent" => @retained_count_percent
         }}
      else
        {default_minimum,
         %{
           "policy" => "prior_complete_retention",
           "prior_count" => prior_count,
           "minimum_count" => default_minimum,
           "retained_percent" => @retained_count_percent
         }}
      end
    else
      {absolute_minimum, nil}
    end
  end

  @doc "Enqueue all enabled feeds that are not already in flight."
  @spec ensure_scheduled() :: {:ok, :scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      reclaim_orphaned_jobs()
      reconcile_stale_runs()

      if Config.enabled?() do
        Enum.each(@feeds, &maybe_enqueue/1)
      end

      {:ok, :scheduled}
    else
      {:error, :oban_unavailable}
    end
  end

  @doc """
  True when an incomplete Oban job exists for `feed`.

  Pass `states:` to narrow (e.g. `["executing"]` for the staging reaper).
  """
  @spec in_flight?(String.t(), keyword()) :: boolean()
  def in_flight?(feed, opts \\ [])

  def in_flight?(feed, opts) when feed in @feeds do
    already_scheduled?(feed, Keyword.get(opts, :states))
  end

  def in_flight?(_feed, _opts), do: false

  @doc "Enqueue a single feed now (operator \"Run now\")."
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(feed, opts \\ [])

  def enqueue(feed, opts) when feed in @feeds and is_list(opts) do
    _ = cancel_incomplete(feed)
    feed |> job_changeset(opts) |> ObanSupport.safe_insert()
  end

  def enqueue(_feed, _opts), do: {:error, :unknown_feed}

  @doc false
  def job_changeset(feed, opts) when feed in @feeds and is_list(opts) do
    if accept_snapshot_contraction?(feed, opts) do
      new(%{feed: feed, accept_snapshot_contraction: true}, max_attempts: 1)
    else
      new(%{feed: feed})
    end
  end

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
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("?->>'feed' = ?", j.args, ^feed)
      ),
      prefix: ObanSupport.prefix()
    )
  rescue
    _ -> {0, nil}
  end

  defp already_scheduled?(feed, states \\ nil) do
    import Ecto.Query

    states = states || ["available", "scheduled", "executing", "retryable"]

    query =
      from(j in Oban.Job,
        where: j.worker == ^@worker_name,
        where: j.state in ^states,
        where: fragment("?->>'feed' = ?", j.args, ^feed),
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  rescue
    _ -> false
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"feed" => feed} = args}) when feed in @feeds do
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
        accept_snapshot_contraction =
          feed in @retained_count_feeds and
            Map.get(args, "accept_snapshot_contraction") == true

        run_feed(feed,
          accept_snapshot_contraction: accept_snapshot_contraction
        )
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("advisory_feeds: unknown feed args #{inspect(args)}")
    {:error, :unknown_feed}
  end

  defp run_feed(feed, opts) do
    actor = SystemActor.system(:advisory_feed_worker)
    started = DateTime.utc_now()

    if Keyword.get(opts, :accept_snapshot_contraction) == true do
      Logger.warning("advisory_feeds: #{feed} operator approved a one-shot snapshot contraction")
    end

    mark_status(
      feed,
      %{last_status: "running", last_attempt_at: started, last_error: nil, last_message: nil},
      actor
    )

    try do
      case do_run(feed, opts) do
        {:ok, result} ->
          Logger.info("advisory_feeds: #{feed} loaded", result: inspect(result))

          mark_status(feed, result_status_attrs({:ok, result}, DateTime.utc_now()), actor)

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

  defp accept_snapshot_contraction?(feed, opts) do
    feed in @retained_count_feeds and
      Keyword.get(opts, :accept_snapshot_contraction) == true
  end

  defp fail_feed(feed, reason, actor) do
    Logger.warning("advisory_feeds: #{feed} failed: #{inspect(reason)}",
      reason: inspect(reason)
    )

    mark_status(feed, result_status_attrs({:error, reason}, DateTime.utc_now()), actor)

    schedule_next(feed)
    {:error, reason}
  end

  @doc """
  Release feed jobs left `executing` by a node that no longer exists.

  A pod replaced mid-run leaves its Oban row in `executing` forever, and because
  this worker's `unique` constraint covers every incomplete state, nothing new can
  be enqueued behind it. `reconcile_stale_runs/1` does not help: it only corrects
  the feed definition's status, and it skips entirely while a job is still
  in-flight. The row itself waits for `Oban.Plugins.Lifeline`, configured at 240
  minutes -- so one deploy roll could cost a 6-hourly feed most of a cycle.

  The test here is node identity and node age, not job age. Oban records the node
  that took the attempt in `attempted_by[0]` (Oban 2.23 writes `[node, uuid]`;
  older versions wrote `[node, queue, uuid]`, so match the head, not the arity).

  There are two ways the owner can die, and only one of them changes the node
  name:

    * **The pod is replaced.** Nodes here are named after the pod IP
      (`serviceradar_core@10.42.x.y`), so the new pod gets a new name and the old
      name simply disappears from the cluster.

    * **The container restarts inside the same pod.** An OOMKill does this: the
      pod keeps its IP, so the BEAM comes back under the *identical* node name.
      Liveness alone cannot see this, and an earlier version of this function
      missed it -- observed on farm01, where a nist-nvd2 run was OOMKilled four
      minutes in (exit 137) and its row then sat `executing` for well over an
      hour under a node name that looked perfectly healthy.

  So a node being present is not enough; it has to be the *same instance*. A node
  whose VM started after the job's `attempted_at` cannot be running that job, no
  matter what it is called. That still needs no threshold on job age, and still
  leaves the global Lifeline setting every other worker shares alone.

  Two guards keep it conservative:

    * it does nothing on an un-clustered node, where `Node.list/0` is empty and
      every job would look orphaned; and
    * it still requires a short grace period, so a brief netsplit does not reclaim
      a job that is genuinely running on the other side of it; and
    * a node whose start time cannot be read is treated as healthy, so an RPC
      timeout cannot cancel a live run.

  Dead attempts are cancelled rather than retried. A half-finished run has already
  written a staging directory and possibly part of a generation; a fresh acquire
  is cheaper to reason about than resuming a corpse, and `ensure_scheduled/0`
  enqueues one immediately afterwards.
  """
  @spec reclaim_orphaned_jobs() :: :ok
  def reclaim_orphaned_jobs do
    if clustered?() do
      do_reclaim_orphaned_jobs()
    else
      :ok
    end
  rescue
    exception ->
      Logger.warning("advisory_feeds: orphan reclaim failed: #{inspect(exception)}")
      :ok
  end

  defp clustered?, do: Node.self() != :nonode@nohost

  defp do_reclaim_orphaned_jobs do
    import Ecto.Query

    live = live_node_start_times()
    cutoff = DateTime.add(DateTime.utc_now(), -@orphan_grace_seconds, :second)

    query =
      from(j in Oban.Job,
        where: j.worker == ^@worker_name,
        where: j.state == "executing",
        where: j.attempted_at < ^cutoff
      )

    query
    |> ServiceRadar.Repo.all(prefix: ObanSupport.prefix())
    |> Enum.filter(&orphaned?(&1, live))
    |> Enum.each(&cancel_orphan/1)

    :ok
  end

  @doc false
  # `live` maps a live node name to the DateTime its VM started, or to nil when
  # that could not be read. No attempted_by means unknown provenance -- leave
  # those to Lifeline rather than guess.
  def orphaned?(job, live)

  def orphaned?(%Oban.Job{attempted_by: [node | _], attempted_at: attempted_at}, live)
      when is_binary(node) do
    case Map.fetch(live, node) do
      # The node is gone from the cluster: the pod was replaced.
      :error ->
        true

      # Present, but we could not read its start time. Assume it is healthy --
      # cancelling a live 60-minute feed run costs more than waiting for Lifeline.
      {:ok, nil} ->
        false

      # Present under the same name, but this VM booted after the job began, so
      # it is not the instance that took the attempt. Container restart in place.
      {:ok, started_at} ->
        restarted_since?(attempted_at, started_at)
    end
  end

  def orphaned?(_job, _live), do: false

  @doc false
  # Public so :rpc can call it on a peer. Derived from the monotonic clock rather
  # than :erlang.statistics(:wall_clock), which resets a global counter as a side
  # effect of being read.
  @spec vm_started_at() :: DateTime.t()
  def vm_started_at do
    uptime_ms =
      :erlang.convert_time_unit(
        :erlang.monotonic_time() - :erlang.system_info(:start_time),
        :native,
        :millisecond
      )

    DateTime.add(DateTime.utc_now(), -uptime_ms, :millisecond)
  end

  defp live_node_start_times do
    self_node = Node.self()

    Map.new([self_node | Node.list()], fn node ->
      {Atom.to_string(node), node_started_at(node, self_node)}
    end)
  end

  defp node_started_at(node, node), do: vm_started_at()

  defp node_started_at(node, _self_node) do
    case :rpc.call(node, __MODULE__, :vm_started_at, [], @rpc_timeout_ms) do
      %DateTime{} = started_at -> started_at
      _other -> nil
    end
  end

  defp restarted_since?(nil, _started_at), do: false

  defp restarted_since?(attempted_at, started_at) do
    DateTime.before?(to_utc(attempted_at), started_at)
  end

  # Oban types attempted_at as :utc_datetime_usec, but normalise anyway: a
  # NaiveDateTime compared against a DateTime raises, and this runs on a path
  # whose whole job is to not disturb anything.
  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp cancel_orphan(%Oban.Job{id: id, args: args, attempted_by: [node | _]}) do
    Logger.warning(
      "advisory_feeds: cancelling orphaned job #{id} for #{inspect(args["feed"])}; " <>
        "node #{node} is gone or restarted since the attempt began"
    )

    Oban.cancel_job(id)
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

  defp do_run("cisa-kev", opts) do
    run_id = run_id()
    url = Config.cisa_kev_url()

    with {:ok, acquired} <- Acquisition.acquire_cisa(url, run_id) do
      with_run_cleanup(acquired, fn ->
        parse_and_load(acquired, "cisa", "cisa-kev", &parse_kev/1, opts)
      end)
    end
  end

  defp do_run("vulncheck-kev", opts) do
    with {:ok, token} <- Config.vulncheck_token(),
         {:ok, acquired} <-
           Acquisition.acquire_vulncheck("vulncheck-kev", token, run_id()) do
      with_run_cleanup(acquired, fn ->
        parse_and_load(acquired, "vulncheck", "vulncheck-kev", &parse_kev/1, opts)
      end)
    end
  end

  defp do_run("nist-nvd2", opts) do
    # Drop leftover extracts *before* a new download. Timeout uses :kill, so
    # with_run_cleanup/2 does not run; without this prune each retry added
    # another zip+extract until the node filled.
    _ = Staging.prune_feed("nist-nvd2", keep: 0)

    if Staging.volume_available?() do
      case Staging.ensure_budget() do
        :ok ->
          with {:ok, token} <- Config.vulncheck_token(),
               {:ok, acquired} <- Acquisition.acquire_vulncheck("nist-nvd2", token, run_id()) do
            with_run_cleanup(acquired, fn -> parse_and_load_nvd(acquired, opts) end)
          end

        {:error, reason} = error ->
          Logger.warning("advisory_feeds: nist-nvd2 staging budget: #{inspect(reason)}")
          error
      end
    else
      Logger.warning(
        "advisory_feeds: staging volume unavailable, skipping nist-nvd2 (fail closed)"
      )

      {:error, :staging_volume_unavailable}
    end
  end

  defp do_run("ubuntu-osv-vex", _opts) do
    _ = Staging.prune_feed("ubuntu-osv-vex", keep: 0)

    with {:ok, entry} <- FeedRegistry.fetch("ubuntu-osv-vex"),
         true <- Staging.volume_available?() || {:error, :staging_volume_unavailable},
         :ok <- Staging.ensure_budget(),
         %{url: osv_url, options: source_options} <- Config.source(entry.feed),
         vex_url when is_binary(vex_url) <- Map.get(source_options, "vex_url"),
         {:ok, acquired} <-
           Acquisition.acquire_ubuntu_pair(entry.feed, osv_url, vex_url, run_id(),
             timeout_ms: 1_800_000
           ) do
      with_run_cleanup(acquired, fn ->
        load_ubuntu_snapshot(acquired, provider: entry.provider, feed_key: entry.feed_key)
      end)
    else
      {:error, _} = error -> error
      other -> {:error, {:invalid_ubuntu_source, other}}
    end
  end

  defp do_run("nvd-api", _opts) do
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

  # The skip guard has failed silently before: a NaiveDateTime/DateTime mismatch
  # made it return false for every record, so the whole corpus was rewritten
  # every run (~5.9 TB of WAL) while every log line still read "success". Zero
  # skips against a non-empty stored corpus is that signature.
  defp warn_if_guard_inert(feed_key, existing_count, result) do
    if existing_count > 0 and result.advisories_upserted > 0 and result.advisories_skipped == 0 do
      Logger.error(
        "advisory_feeds: #{feed_key} skip guard appears inert — #{existing_count} stored " <>
          "advisories, 0 skipped, #{result.advisories_upserted} rewritten"
      )
    end

    result
  end

  defp load_and_finalize(records_factory, provider, feed_key, opts) do
    existing_state = Loader.existing_comparison_state(provider, feed_key)
    existing_count = Loader.comparable_count(feed_key, existing_state)
    required_tree = Keyword.get(opts, :required_tree, feed_key)
    absolute_minimum = Keyword.get(opts, :expected_minimum, 1)

    {expected_minimum, retained_count_floor} =
      snapshot_minimum(feed_key, map_size(existing_state), absolute_minimum,
        accept_snapshot_contraction: Keyword.get(opts, :accept_snapshot_contraction) == true
      )

    preflight_opts = Keyword.put(opts, :expected_minimum, expected_minimum)

    preflight_opts =
      if retained_count_floor do
        Keyword.put(preflight_opts, :retained_count_floor, retained_count_floor)
      else
        preflight_opts
      end

    completeness = preflight(records_factory, required_tree, preflight_opts)

    with :ok <- Loader.validate_completeness(completeness) do
      generation = Loader.next_generation(provider, feed_key)

      records =
        Stream.flat_map(records_factory.(), fn
          {:record, record} -> [record]
          :skip -> []
          {:read_error, reason} -> raise "source changed after preflight: #{inspect(reason)}"
          {:parse_error, reason} -> raise "source changed after preflight: #{inspect(reason)}"
        end)

      with {:ok, result} <-
             Loader.load_and_finalize(records,
               provider: provider,
               feed_key: feed_key,
               generation: generation,
               existing_state: existing_state,
               normalization_version: Keyword.get(opts, :normalization_version),
               completeness: completeness
             ) do
        {:ok, warn_if_guard_inert(feed_key, existing_count, result)}
      end
    end
  end

  defp parse_and_load(acquired, provider, feed_key, parse_fun, opts) do
    json_path = single_json(acquired.extracted_dir)

    records_factory = fn ->
      json_path
      |> StreamReader.stream_json_file(records_key: records_key(feed_key))
      |> Stream.map(
        &parse_source_item(&1, fn record -> parse_fun.({record, provider, feed_key}) end)
      )
    end

    load_and_finalize(
      records_factory,
      provider,
      feed_key,
      Keyword.put(opts, :required_tree, records_key(feed_key))
    )
  end

  defp parse_and_load_nvd(acquired, opts) do
    provider = "nvd"
    feed_key = "nist-nvd2"

    records_factory = fn ->
      acquired.extracted_dir
      |> StreamReader.stream_nvd_shards()
      |> Stream.map(
        &parse_source_item(&1, fn record ->
          Parsers.Nvd.parse_record(record, provider: provider, feed_key: feed_key)
        end)
      )
    end

    load_and_finalize(
      records_factory,
      provider,
      feed_key,
      opts
      |> Keyword.put(:normalization_version, Parsers.Nvd.normalization_version())
      |> Keyword.put(:required_tree, "vulnerabilities")
    )
  end

  @doc false
  def load_ubuntu_snapshot(acquired, opts \\ [])

  def load_ubuntu_snapshot(%{format: :ubuntu_tar_xz_pair} = acquired, opts) do
    provider = Keyword.get(opts, :provider, "ubuntu")
    feed_key = Keyword.get(opts, :feed_key, "ubuntu-osv-vex")

    adapter_opts =
      Keyword.take(opts, [
        :helper,
        :helper_args_prefix,
        :runner,
        :port_timeout_ms,
        :provider,
        :feed_key
      ])

    with {:ok, snapshot} <- UbuntuAdapter.prepare_pair(acquired, adapter_opts),
         :ok <- Loader.validate_completeness(snapshot.completeness) do
      generation = Loader.next_generation(provider, feed_key)
      existing_state = Loader.existing_comparison_state(provider, feed_key)
      existing_count = Loader.comparable_count(feed_key, existing_state)

      records =
        Stream.map(snapshot.records, fn
          {:ok, record} -> record
          {:error, reason} -> raise "Ubuntu helper parse failure: #{inspect(reason)}"
        end)

      completeness =
        Map.update!(snapshot.completeness, :validation, fn validation ->
          Map.put(validation, "publication", %{
            "complete" => true,
            "count" => snapshot.completeness.source_objects_seen,
            "generation_provenance" => acquired.generation_provenance,
            "osv" => acquired.artifacts.osv,
            "vex" => acquired.artifacts.vex,
            "acquired_at" => DateTime.to_iso8601(acquired.acquired_at)
          })
        end)

      with {:ok, result} <-
             Loader.load_and_finalize(records,
               provider: provider,
               feed_key: feed_key,
               generation: generation,
               existing_state: existing_state,
               normalization_version: Parsers.Ubuntu.normalization_version(),
               completeness: completeness,
               transaction_timeout_ms: 3_600_000,
               timeout_ms: 1_800_000
             ) do
        {:ok, warn_if_guard_inert(feed_key, existing_count, result)}
      end
    end
  end

  def load_ubuntu_snapshot(_acquired, _opts), do: {:error, :invalid_ubuntu_acquired_pair}

  defp parse_source_item({:error, {:read_error, _, _} = reason}, _parser),
    do: {:read_error, reason}

  defp parse_source_item({:error, reason}, _parser), do: {:parse_error, reason}

  defp parse_source_item({:ok, record}, parser) do
    case parser.(record) do
      {:ok, mapped} -> {:record, mapped}
      [mapped] -> {:record, mapped}
      :skip -> :skip
      [] -> :skip
      other -> {:parse_error, {:invalid_parser_result, other}}
    end
  rescue
    error -> {:parse_error, {error, __STACKTRACE__}}
  end

  @doc false
  def preflight(records_factory, required_tree, opts) do
    summary =
      Enum.reduce(records_factory.(), %{seen: 0, parse_errors: 0, read_errors: 0}, fn
        {:record, _record}, acc -> %{acc | seen: acc.seen + 1}
        :skip, acc -> %{acc | parse_errors: acc.parse_errors + 1}
        {:parse_error, _reason}, acc -> %{acc | parse_errors: acc.parse_errors + 1}
        {:read_error, _reason}, acc -> %{acc | read_errors: acc.read_errors + 1}
      end)

    put_retained_count_floor(
      %{
        complete_snapshot?: summary.parse_errors == 0 and summary.read_errors == 0,
        source_objects_seen: summary.seen,
        expected_minimum: Keyword.get(opts, :expected_minimum, 1),
        parse_errors: summary.parse_errors,
        read_errors: summary.read_errors,
        required_trees: [required_tree],
        validation: %{
          to_string(required_tree) => %{
            "complete" => summary.parse_errors == 0 and summary.read_errors == 0,
            "count" => summary.seen
          }
        }
      },
      opts,
      required_tree,
      summary.seen
    )
  rescue
    error ->
      put_retained_count_floor(
        %{
          complete_snapshot?: false,
          source_objects_seen: 0,
          expected_minimum: Keyword.get(opts, :expected_minimum, 1),
          parse_errors: 1,
          read_errors: 0,
          required_trees: [required_tree],
          validation: %{to_string(required_tree) => %{"complete" => false, "count" => 0}},
          error: Exception.message(error)
        },
        opts,
        required_tree,
        0
      )
  end

  defp put_retained_count_floor(completeness, opts, required_tree, observed_count) do
    case Keyword.get(opts, :retained_count_floor) do
      floor when is_map(floor) ->
        floor = Map.put(floor, "observed_count", observed_count)

        completeness
        |> Map.put(:retained_count_floor, floor)
        |> put_in(
          [:validation, to_string(required_tree), "retained_count_floor"],
          floor
        )

      _ ->
        completeness
    end
  end

  @doc false
  def result_status_attrs({:error, reason}, now) do
    %{last_status: "error", last_failure_at: now, last_error: inspect(reason)}
  end

  def result_status_attrs({:ok, result}, _now) do
    %{
      last_status: "success",
      last_success_at: result.complete_generation_at,
      last_message:
        "loaded #{result.advisories_upserted} advisories " <>
          "(#{result.advisories_skipped} unchanged)",
      last_error: nil,
      metadata: %{
        "advisories" => result.advisories_upserted,
        "coordinates" => result.coordinates_upserted,
        "assertions" => result.assertions_upserted,
        "advisories_skipped" => result.advisories_skipped,
        "source_objects_seen" => result.source_objects_seen,
        "parse_errors" => result.parse_errors,
        "read_errors" => result.read_errors,
        "generation" => result.generation,
        "complete_generation_at" => DateTime.to_iso8601(result.complete_generation_at),
        "validation" => result.validation
      }
    }
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

  @doc false
  def mark_status(feed, attrs, actor) do
    {provider, feed_key} = provider_feed(feed)

    case VulnerabilityFeedDefinition
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(provider == ^provider and feed_key == ^feed_key)
         |> Ash.read_one(actor: actor) do
      {:ok, %VulnerabilityFeedDefinition{} = def} ->
        attrs = merge_status_metadata(def.metadata, attrs)

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

  defp merge_status_metadata(current_metadata, %{metadata: status_metadata} = attrs)
       when is_map(status_metadata) do
    Map.put(attrs, :metadata, Map.merge(current_metadata || %{}, status_metadata))
  end

  defp merge_status_metadata(_current_metadata, attrs), do: attrs

  defp provider_feed("nvd-api"), do: {"nvd", "nvd-api"}

  defp provider_feed(feed) do
    {:ok, entry} = FeedRegistry.fetch(feed)
    {entry.provider, entry.feed_key}
  end

  defp schedule_next(feed) do
    if Config.feed_enabled?(feed) do
      seconds = Config.refresh_seconds(feed)

      _ =
        feed
        |> then(&%{feed: &1})
        |> then(&SelfScheduling.successor_changeset(__MODULE__, &1, seconds))
        |> ObanSupport.safe_insert()
    end

    :ok
  end

  defp run_id do
    DateTime.utc_now()
    |> DateTime.to_unix(:millisecond)
    |> Integer.to_string()
  end
end
