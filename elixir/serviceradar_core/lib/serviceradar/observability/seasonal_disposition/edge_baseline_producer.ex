defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer do
  @moduledoc """
  Builds the per-series hour-of-week `seasonal_baselines` payload and delivers it
  to the edge anomaly add-on (OpenSpec task 2.6 — edge-baseline DELIVERY).

  Reuses `Worker.edge_baseline_rows/2` for SRQL pagination and row hydration,
  with chunk planning in `batched_baseline_rows/2`, then reduces profile rows via
  `EdgeBaseline.build/2`. Delivery scope and operator-facing behavior are described
  in `docs/docs/anomaly-engine.md` under Seasonal Baselines.

  ## Series-key alignment (the crux)

  The central profile is keyed by SRQL `series:uid` (`device_id AS series`), i.e.
  one device-level series per metric. The edge add-on resolves a sample's seasonal
  baseline by the canonical `<device_uid>|<metric_name>` key it derives at scoring
  time (`identity::seasonal_series_key`). So this producer keys each delivered
  baseline by `<device_id>|<wire_metric_name>` — the SAME string the add-on
  derives — where `wire_metric_name` is the full dotted metric name the agent
  stamps (e.g. `memory.used_percent`). That reconciliation is what makes a
  delivered baseline actually resolve at the edge.

  Background Ash access uses `ServiceRadar.Actors.SystemActor` (never
  `authorize?: false`). Tests can inject `:sources`, `:runner`, `:profiles_loader`,
  `:profile_updater`, `:reconcile_fun`, and `:heartbeat_recorder`; production uses
  the seasonal sources, `SRQLRunner`, the Ash-backed `AddonProfile` read/update +
  reconcile, and the `HealthTracker`-backed heartbeat.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:trigger]
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.Infrastructure.HealthTracker
  alias ServiceRadar.Observability.SeasonalDisposition.EdgeBaseline
  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Observability.SeasonalDisposition.Worker
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @addon_id "anomaly"
  @params_key "seasonal_baselines"
  @heartbeat_check_id "seasonal-baseline-producer"
  @default_interface_top_k_per_device 16
  @default_interface_min_history_weeks 3
  # Kept in lockstep with anomaly-core's DEFAULT_SEASONAL_MIN_BUCKET_SAMPLES.
  # A baseline with thinner buckets is payload that the edge will silently reject.
  @default_min_bucket_samples 4
  @default_min_bucket_coverage_fraction 0.60
  @default_max_baselines_per_agent 1_000
  # Series budget for batched_baseline_rows/2. Each IN list is also bounded by
  # the SRQL parser's MAX_FILTER_LIST_VALUES.
  @default_max_combos_per_query 200
  @srql_max_filter_list_values 200
  # Host devices per full-profile statement. The statement cost is devices x 168
  # buckets x the whole history and grows NON-linearly with the device count
  # (demo, 30 s statement_timeout: 1 device 2.5-3.3 s, 5 devices 0.8 s, 10 devices
  # cancelled, 20 devices cancelled), so a device-count budget is data dependent.
  # One device per statement is the only sizing that is predictable across fleets
  # and matches the interface path; raise it only where headroom was measured.
  @default_max_devices_per_query 1
  @delivery_telemetry [:serviceradar, :seasonal_disposition, :edge_baseline, :delivery]

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    case reconcile(run_opts(job)) do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Build the merged `seasonal_baselines` payload across every supported source.

  Host series use the legacy bucket-object encoding. Interface series use the
  governed compact encoding and are merged here only for tests/inspection; normal
  delivery uses `build_scoped/1` so interface baselines go only to their matching
  agent assignments.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts \\ []) do
    with {:ok, delivery} <- build_delivery(opts) do
      {:ok, merged_baselines(delivery)}
    end
  end

  @doc """
  Build the governed delivery plan.

  `:global_baselines` are safe to place on the profile because every matched
  assignment may receive them (host-level CPU/memory). `:scoped_baselines` are
  keyed by agent/partition scope and must be written onto individual
  `AddonAssignment.params` only.
  """
  @spec build_scoped(keyword()) :: {:ok, map()} | {:error, term()}
  def build_scoped(opts \\ []) do
    build_delivery(opts)
  end

  # One failed source must not silence the others: the sources that fetched are
  # delivered and the failures ride along in `failed_sources`, so the heartbeat
  # can be recorded unhealthy WITH a reason. Only a run where nothing fetched is
  # an error (there is nothing to deliver and Oban's retry is the right response).
  defp build_delivery(opts, emit_telemetry? \\ true) do
    {deliveries, failures} =
      opts
      |> sources()
      |> Enum.reduce({[], []}, fn source, {deliveries, failures} ->
        case source_delivery(source, opts) do
          {:ok, delivery} -> {[delivery | deliveries], failures}
          {:error, _reason} -> {deliveries, [source.name | failures]}
        end
      end)

    failed_sources = Enum.reverse(failures)

    if deliveries == [] and failed_sources != [] do
      {:error, {:all_sources_failed, failed_sources}}
    else
      delivery =
        deliveries
        |> Enum.reverse()
        |> Enum.reduce(empty_delivery(), fn delivery, acc -> merge_delivery(acc, delivery) end)
        |> Map.put(:failed_sources, failed_sources)

      governed = govern_interface_candidates(delivery, opts)

      if emit_telemetry?, do: emit_delivery_telemetry(governed)

      {:ok, governed}
    end
  end

  @doc """
  Build the payload and deliver it. Host baselines are written onto every enabled
  anomaly `AddonProfile`'s profile params; interface baselines are written onto
  matching profile-owned `AddonAssignment.params` after the optional reconcile.
  A profile/assignment whose params already carry a byte-equal
  `"seasonal_baselines"` payload is skipped, so an unchanged hourly run causes
  no param writes and no agent config redelivery. Every successful run records
  a `#{@heartbeat_check_id}` heartbeat health event — the freshness tripwire
  (`SeasonalBaselineFreshnessWorker`) reads its recency to tell "delivery is
  running" from "delivery silently died". Returns a summary map.
  """
  @spec reconcile(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:seasonal_edge_baseline_producer))

    with {:ok, delivery} <- build_delivery(opts, false),
         {:ok, profiles} <- load_profiles(opts, actor),
         {:ok, assignments} <- load_scoped_assignments(profiles, delivery, opts, actor),
         delivery = resolve_assignment_scopes(delivery, assignments, opts, actor),
         :ok <- emit_delivery_telemetry(delivery),
         {:ok, {refreshed, changed}} <-
           update_profiles(profiles, delivery.global_baselines, opts, actor),
         :ok <- maybe_reconcile(changed, opts, actor),
         {:ok, assignment_summary} <-
           update_assignments(assignments, delivery, opts, actor) do
      summary = %{
        series: delivery.stats.global_series + delivery.stats.scoped_series,
        global_series: delivery.stats.global_series,
        scoped_series: delivery.stats.scoped_series,
        scoped_agents: map_size(delivery.scoped_baselines),
        truncated_series: delivery.stats.cap_dropped,
        profiles_updated: length(changed),
        profiles_total: length(refreshed),
        assignments_updated: assignment_summary.updated,
        assignments_total: assignment_summary.total,
        failed_sources: Map.get(delivery, :failed_sources, [])
      }

      record_heartbeat(summary, opts)
      {:ok, summary}
    end
  end

  @doc "Health-event entity id of the producer's per-run delivery heartbeat."
  @spec heartbeat_check_id() :: String.t()
  def heartbeat_check_id, do: @heartbeat_check_id

  @spec enqueue_now(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now(opts \\ []) do
    if ObanSupport.available?() do
      %{"trigger" => "manual"}
      |> new(opts)
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  # --- baseline construction -------------------------------------------------

  defp source_delivery(%Source{} = source, opts) do
    # Central disposition continues to use its established latest-bucket SRQL
    # route.  Edge delivery is the only consumer that needs the complete 168
    # bucket profile, so upgrade a private copy of the source query here.
    case batched_baseline_rows(source, opts) do
      {:ok, rows} ->
        {:ok, keyed_delivery(source, rows, opts)}

      {:error, reason} ->
        # The release log format prints the message only (logger metadata is
        # dropped), so the source and reason must be in the body to be visible.
        Logger.warning(
          "Edge baseline source fetch failed source=#{source.name} reason=#{inspect(reason)}",
          source: source.name,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Fetch the full 168-bucket profile in per-device chunks. A single fleet-wide
  # full-profile statement aggregates 180 days x every series (with two
  # `percentile_cont` passes) and exceeds the database statement_timeout as the
  # fleet grows; the outer SRQL `limit:` cannot bound that input. So first run
  # the source's latest-bucket query (one row per series — the same cost profile
  # as the central disposition verdict pass) to learn the device cohort, then
  # run the full-profile query once per device chunk with a `device_id:(...)`
  # filter, splitting interface sources further with disjoint `if_index:(...)`
  # filters. Aggregation is per series, so
  # concatenating chunk rows yields exactly the fleet-wide result while each
  # statement's input stays bounded by `:edge_baseline_max_combos_per_query`.
  defp batched_baseline_rows(%Source{query: query} = source, opts) when is_binary(query) do
    max_combos = max_combos_per_query(opts)

    with {:ok, discovery} <- Worker.edge_baseline_rows(source, opts) do
      discovery
      |> plan_device_chunks(source, max_combos, opts)
      |> fetch_device_chunks(source, opts)
    end
  end

  defp batched_baseline_rows(source, opts) do
    Worker.edge_baseline_rows(full_profile_source(source), opts)
  end

  defp max_combos_per_query(opts) do
    max(int_opt(opts, :edge_baseline_max_combos_per_query, @default_max_combos_per_query), 1)
  end

  defp max_devices_per_query(opts) do
    opts
    |> int_opt(:edge_baseline_max_devices_per_query, @default_max_devices_per_query)
    |> max(1)
    |> min(@srql_max_filter_list_values)
  end

  # Interface identities are disjoint within a device. Scope each statement to
  # one device and a bounded IN list so even a wide device cannot exceed the cap.
  defp plan_device_chunks(discovery_rows, %Source{resource_type: "interface"}, max_combos, _opts) do
    discovery_rows
    |> Enum.group_by(& &1.series_key, & &1.if_index)
    |> Enum.sort_by(fn {device, _indexes} -> device end)
    |> Enum.flat_map(fn {device, indexes} ->
      indexes
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.chunk_every(min(max_combos, @srql_max_filter_list_values))
      |> Enum.map(&%{devices: [device], if_indexes: &1})
    end)
  end

  # Host sources have one series per device. A series is NOT the cost unit of a
  # full-profile statement (see `@default_max_devices_per_query`), so hosts are
  # chunked by device count, one per statement by default.
  defp plan_device_chunks(discovery_rows, _source, _max_combos, opts) do
    discovery_rows
    |> Enum.map(& &1.series_key)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(max_devices_per_query(opts))
    |> Enum.map(&%{devices: &1, if_indexes: []})
  end

  defp fetch_device_chunks([], _source, _opts), do: {:ok, []}

  defp fetch_device_chunks(chunks, source, opts) do
    Logger.debug("Fetching seasonal edge baselines in device chunks",
      source: source.name,
      devices: chunks |> Enum.flat_map(& &1.devices) |> Enum.uniq() |> length(),
      chunks: length(chunks)
    )

    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      case Worker.edge_baseline_rows(full_profile_source(chunk_source(source, chunk)), opts) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp chunk_source(%Source{query: query} = source, %{devices: devices, if_indexes: indexes})
       when is_binary(query) do
    interface_filter = if indexes == [], do: "", else: " if_index:(#{Enum.join(indexes, ",")})"
    %{source | query: query <> " " <> devices_filter(devices) <> interface_filter}
  end

  defp devices_filter(devices) do
    ids = Enum.map_join(devices, ",", &quote_srql_string/1)
    "device_id:(#{ids})"
  end

  defp quote_srql_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp full_profile_source(%Source{query: query} = source) when is_binary(query) do
    %{
      source
      | query: String.replace(query, "profile_hour_of_week(", "profile_hour_of_week_full(")
    }
  end

  # `EdgeBaseline.build/2` groups by `row.series_key`, so rewrite rows to the
  # delivered edge-baseline lookup key before building. Host sources keep the
  # historical `<device_uid>|<metric_name>` key; interface sources include
  # `if_index` so separate ports on one device cannot collapse.
  defp keyed_delivery(%Source{resource_type: "interface"} = source, rows, opts) do
    {candidates, quality_dropped} = interface_candidates(source, rows, opts)

    %{
      empty_delivery()
      | interface_candidates: candidates,
        stats: %{
          empty_delivery().stats
          | interface_sources: 1,
            interface_candidates: length(candidates),
            quality_dropped: quality_dropped
        }
    }
  end

  defp keyed_delivery(%Source{} = source, rows, opts) do
    {baselines, quality_dropped} = keyed_baselines(source, rows, :buckets, opts)

    %{
      empty_delivery()
      | global_baselines: baselines,
        stats: %{
          empty_delivery().stats
          | global_series: map_size(baselines),
            quality_dropped: quality_dropped
        }
    }
  end

  defp keyed_baselines(%Source{} = source, rows, encoding, opts) do
    rows
    |> Enum.map(&Map.put(&1, :series_key, seasonal_series_key(source, &1)))
    |> Enum.group_by(&Map.fetch!(&1, :series_key))
    |> Enum.reduce({%{}, 0}, fn {_series_key, series_rows}, {baselines, dropped} ->
      rows = qualified_rows(series_rows, opts)

      if coverage_ready?(rows, opts) do
        built = EdgeBaseline.build(rows, source.robust_statistic, encoding: encoding)
        {Map.merge(baselines, built), dropped}
      else
        {baselines, dropped + 1}
      end
    end)
  end

  defp seasonal_series_key(%Source{} = source, row) do
    metric_name = source.wire_metric_name

    case {source.resource_type, Map.get(row, :if_index)} do
      {"interface", if_index} when is_integer(if_index) and if_index > 0 ->
        # SNMP add-ons derive their seasonal key from target_device_ip, while
        # the CAGG `series` is the canonical sr: device uid. Preserve the
        # latter for polling-agent resolution, but deliver under the identity
        # the edge will actually look up.
        edge_device_uid = string_value(row, [:target_device_ip]) || Map.get(row, :series_key)
        "#{edge_device_uid}|#{metric_name}|#{if_index}"

      _ ->
        "#{Map.get(row, :series_key)}|#{metric_name}"
    end
  end

  defp interface_candidates(%Source{} = source, rows, opts) do
    min_history_weeks =
      int_opt(opts, :interface_min_history_weeks, @default_interface_min_history_weeks)

    rows
    |> Enum.map(fn row ->
      row
      |> Map.put(:device_uid, Map.get(row, :series_key))
      |> Map.put(:series_key, seasonal_series_key(source, row))
      # The edge lookup key is intentionally IP-based for SNMP, but it is not a
      # safe aggregation key: two sites can legitimately have the same RFC1918
      # address. Build each profile from its canonical device identity, then
      # fan that completed profile to the correct polling-agent scope.
      |> Map.put(:candidate_key, canonical_interface_candidate_key(source, row))
    end)
    |> Enum.group_by(&Map.get(&1, :candidate_key))
    |> Enum.reduce({[], 0}, fn {_candidate_key, group_rows}, {candidates, dropped} ->
      series_key = group_value(group_rows, :series_key)
      qualified_rows = qualified_rows(group_rows, opts, min_history_weeks)

      if coverage_ready?(qualified_rows, opts) do
        payload =
          qualified_rows
          |> EdgeBaseline.build(source.robust_statistic, encoding: :compact_168)
          |> Map.get(series_key)

        case payload do
          nil ->
            {candidates, dropped + 1}

          payload ->
            {[
               %{
                 series_key: series_key,
                 baseline: payload,
                 scope: interface_scope(group_rows),
                 device_uid: group_value(group_rows, :device_uid),
                 if_index: group_value(group_rows, :if_index),
                 metric_name: source.wire_metric_name,
                 traffic_score: traffic_score(group_rows),
                 bucket_count: length(qualified_rows)
               }
               | candidates
             ], dropped}
        end
      else
        {candidates, dropped + 1}
      end
    end)
    |> then(fn {candidates, dropped} -> {Enum.reverse(candidates), dropped} end)
  end

  defp canonical_interface_candidate_key(%Source{} = source, row) do
    "#{Map.get(row, :series_key)}|#{source.wire_metric_name}|#{Map.get(row, :if_index)}"
  end

  defp qualified_rows(rows, opts, min_history_weeks \\ 0) do
    min_samples =
      max(min_history_weeks, int_opt(opts, :min_bucket_samples, @default_min_bucket_samples))

    Enum.filter(rows, fn row -> sample_count(row) >= min_samples end)
  end

  defp coverage_ready?(rows, opts) do
    min_fraction =
      float_opt(opts, :min_bucket_coverage_fraction, @default_min_bucket_coverage_fraction)

    required = ceil(168 * min_fraction)

    rows
    |> Enum.map(fn row -> {get(row, :dow), get(row, :hod)} end)
    |> Enum.filter(fn {dow, hod} -> dow in 0..6 and hod in 0..23 end)
    |> MapSet.new()
    |> MapSet.size()
    |> Kernel.>=(required)
  end

  defp sample_count(row) do
    case get(row, :bucket_count) do
      count when is_integer(count) and count >= 0 -> count
      count when is_float(count) and count >= 0.0 -> trunc(count)
      _ -> 0
    end
  end

  defp traffic_score(rows) do
    {weighted_sum, total_weight} =
      Enum.reduce(rows, {0.0, 0}, fn row, {sum, count} ->
        weight = max(sample_count(row), 1)

        value =
          abs(number_value(get(row, :center)) || number_value(get(row, :sample_value)) || 0.0)

        {sum + value * weight, count + weight}
      end)

    if total_weight > 0, do: weighted_sum / total_weight, else: 0.0
  end

  defp interface_scope(rows) do
    Enum.find_value(rows, fn row ->
      string_value(row, [:agent_uid, :agent_id, :partition])
    end)
  end

  defp group_value(rows, key), do: Enum.find_value(rows, &get(&1, key))

  defp govern_interface_candidates(delivery, opts) do
    govern_interface_candidates(delivery, opts, delivery.interface_candidates)
  end

  defp govern_interface_candidates(delivery, opts, candidates) do
    top_k = int_opt(opts, :interface_top_k_per_device, @default_interface_top_k_per_device)
    cap = int_opt(opts, :max_baselines_per_agent, @default_max_baselines_per_agent)

    {scoped_candidates, scope_dropped} =
      Enum.split_with(candidates, fn candidate ->
        is_binary(candidate.scope) and candidate.scope != ""
      end)

    allowed_interfaces = top_interfaces(scoped_candidates, top_k)

    {top_candidates, topk_dropped} =
      Enum.split_with(scoped_candidates, fn candidate ->
        MapSet.member?(
          allowed_interfaces,
          {candidate.scope, candidate.device_uid, candidate.if_index}
        )
      end)

    {scoped_baselines, cap_dropped} = cap_candidates_by_scope(top_candidates, cap)

    stats =
      delivery.stats
      |> Map.put(
        :scoped_series,
        scoped_baselines |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum()
      )
      |> Map.put(:scope_dropped, length(scope_dropped))
      |> Map.put(:topk_dropped, length(topk_dropped))
      |> Map.put(:cap_dropped, cap_dropped)

    %{delivery | scoped_baselines: scoped_baselines, stats: stats}
  end

  defp top_interfaces(candidates, top_k) do
    candidates
    |> Enum.group_by(fn candidate -> {candidate.scope, candidate.device_uid} end)
    |> Enum.flat_map(fn {{scope, device_uid}, scoped_device_candidates} ->
      scoped_device_candidates
      |> Enum.group_by(& &1.if_index)
      |> Enum.map(fn {if_index, iface_candidates} ->
        score = iface_candidates |> Enum.map(& &1.traffic_score) |> Enum.max(fn -> 0.0 end)
        {if_index, score}
      end)
      |> Enum.sort_by(fn {if_index, score} -> {-score, if_index || 0} end)
      |> Enum.take(top_k)
      |> Enum.map(fn {if_index, _score} -> {scope, device_uid, if_index} end)
    end)
    |> MapSet.new()
  end

  defp cap_candidates_by_scope(candidates, cap) do
    candidates
    |> Enum.group_by(& &1.scope)
    |> Enum.reduce({%{}, 0}, fn {scope, scoped_candidates}, {acc, dropped_total} ->
      sorted =
        Enum.sort_by(scoped_candidates, fn candidate ->
          {-candidate.traffic_score, candidate.series_key}
        end)

      {kept, dropped} = Enum.split(sorted, cap)

      baselines =
        Map.new(kept, fn candidate -> {candidate.series_key, candidate.baseline} end)

      {Map.put(acc, scope, baselines), dropped_total + length(dropped)}
    end)
  end

  defp merged_baselines(%{global_baselines: global, scoped_baselines: scoped}) do
    Enum.reduce(scoped, global, fn {_scope, baselines}, acc -> Map.merge(acc, baselines) end)
  end

  defp empty_delivery do
    %{
      global_baselines: %{},
      scoped_baselines: %{},
      interface_candidates: [],
      failed_sources: [],
      stats: %{
        global_series: 0,
        scoped_series: 0,
        interface_sources: 0,
        interface_candidates: 0,
        scope_dropped: 0,
        topk_dropped: 0,
        cap_dropped: 0,
        quality_dropped: 0
      }
    }
  end

  defp merge_delivery(left, right) do
    %{
      left
      | global_baselines: Map.merge(left.global_baselines, right.global_baselines),
        interface_candidates: left.interface_candidates ++ right.interface_candidates,
        stats: merge_stats(left.stats, right.stats)
    }
  end

  defp merge_stats(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  defp sources(opts) do
    sources =
      case Keyword.fetch(opts, :sources) do
        {:ok, sources} -> sources
        :error -> Source.defaults(opts)
      end

    sources
    |> Enum.map(&Source.from_config/1)
    |> Enum.filter(&Source.baseline_delivery_supported?/1)
  end

  # --- delivery (AddonProfile params) ----------------------------------------

  defp load_profiles(opts, actor) do
    case Keyword.get(opts, :profiles_loader) do
      loader when is_function(loader, 1) ->
        loader.(actor)

      _ ->
        AddonProfile
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(addon_id == ^@addon_id and enabled == true)
        |> Ash.read(actor: actor)
    end
  end

  # Returns `{:ok, {refreshed, changed}}`: every profile (updated in place when
  # written), plus the subset that actually changed. A profile already carrying
  # a byte-equal payload is skipped — no param write, no reconcile fan-out, no
  # agent config redelivery on unchanged hourly runs.
  defp update_profiles(profiles, baselines, opts, actor) do
    updater = profile_updater(opts)

    Enum.reduce_while(profiles, {:ok, {[], []}}, fn profile, {:ok, {refreshed, changed}} ->
      params = profile_params(profile)
      merged_params = merge_params(params, baselines, opts)

      if params == merged_params do
        {:cont, {:ok, {[profile | refreshed], changed}}}
      else
        case updater.(profile, merged_params, actor) do
          {:ok, updated} -> {:cont, {:ok, {[updated | refreshed], [updated | changed]}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp profile_updater(opts) do
    case Keyword.get(opts, :profile_updater) do
      fun when is_function(fun, 3) ->
        fun

      _ ->
        fn %AddonProfile{} = profile, params, actor ->
          profile
          |> Ash.Changeset.for_update(:update, %{params: params}, actor: actor)
          |> Ash.update(actor: actor)
        end
    end
  end

  # An empty payload still writes `seasonal_baselines: %{}`, clearing any stale
  # delivered baselines so the edge reverts to the rolling-only path (back-compat).
  # Do not unconditionally add new seasonal keys here: profile and assignment
  # params are validated against the package schema currently stored in CNPG,
  # which may still be the prior add-on version during a rollout. The edge's
  # default remains in lockstep with this producer's eligibility gate.
  defp merge_params(params, baselines, _opts) when is_map(params) do
    Map.put(params, @params_key, baselines)
  end

  defp merge_params(_params, baselines, opts), do: merge_params(%{}, baselines, opts)

  defp profile_params(%AddonProfile{params: params}) when is_map(params), do: params
  defp profile_params(%{params: params}) when is_map(params), do: params
  defp profile_params(_profile), do: %{}

  defp load_scoped_assignments(profiles, delivery, opts, actor) do
    if delivery.stats.interface_sources > 0 or Keyword.has_key?(opts, :assignments_loader) do
      load_assignments(profiles, opts, actor)
    else
      {:ok, []}
    end
  end

  # Interface hourly rows carry a collection partition, not the identity of the
  # agent that polled the target.  Resolve ownership from the same SNMP profile
  # resolver that builds agent config, then fan the baseline out to every enabled
  # anomaly assignment for a polling agent.  The old partition->agent_uid lookup
  # made interface baselines structurally undeliverable.
  defp resolve_assignment_scopes(delivery, assignments, opts, actor) do
    assignment_agent_uids =
      assignments
      |> Enum.map(&assignment_agent_uid/1)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    agents_by_device =
      delivery.interface_candidates
      |> Enum.map(& &1.device_uid)
      |> Enum.uniq()
      |> Map.new(fn device_uid ->
        {device_uid, polling_agents(device_uid, assignment_agent_uids, opts, actor)}
      end)

    candidates =
      Enum.flat_map(delivery.interface_candidates, fn candidate ->
        agents_by_device
        |> Map.get(candidate.device_uid, [])
        |> Enum.map(&Map.put(candidate, :scope, &1))
      end)

    govern_interface_candidates(%{delivery | scoped_baselines: %{}}, opts, candidates)
  end

  defp polling_agents(device_uid, assignment_agent_uids, opts, actor) do
    resolver =
      Keyword.get(opts, :polling_agents_resolver, fn device_uid, agent_uids, actor ->
        Enum.filter(agent_uids, fn agent_uid ->
          match?(%{enabled: true}, SNMPCompiler.resolve_profile(device_uid, agent_uid, actor))
        end)
      end)

    case resolver.(device_uid, assignment_agent_uids, actor) do
      agents when is_list(agents) ->
        agents
        |> Enum.filter(&(&1 in assignment_agent_uids))
        |> Enum.uniq()

      _ ->
        []
    end
  rescue
    error ->
      Logger.warning("Failed to resolve seasonal interface polling agents",
        device_uid: device_uid,
        reason: Exception.message(error)
      )

      []
  end

  defp load_assignments(profiles, opts, actor) do
    case Keyword.get(opts, :assignments_loader) do
      loader when is_function(loader, 2) ->
        loader.(profiles, actor)

      _ ->
        Enum.reduce_while(profiles, {:ok, []}, fn profile, {:ok, acc} ->
          case load_profile_assignments(profile, actor) do
            {:ok, assignments} -> {:cont, {:ok, acc ++ assignments}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp load_profile_assignments(profile, actor) do
    case profile_id(profile) do
      id when is_binary(id) and id != "" ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} ->
            AddonAssignment
            |> Ash.Query.for_read(:by_profile, %{addon_profile_id: uuid}, actor: actor)
            |> Ash.Query.filter(enabled == true and addon_id == ^@addon_id)
            |> Ash.read(actor: actor)

          :error ->
            {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  defp update_assignments(assignments, delivery, opts, actor) do
    updater = assignment_updater(opts)

    Enum.reduce_while(
      assignments,
      {:ok, %{updated: 0, total: length(assignments)}},
      fn assignment, {:ok, stats} ->
        scope = assignment_agent_uid(assignment)
        scoped = Map.get(delivery.scoped_baselines, scope, %{})
        baselines = Map.merge(delivery.global_baselines, scoped)
        params = assignment_params(assignment)
        merged_params = merge_params(params, baselines, opts)

        if params == merged_params do
          # Unchanged payload: skip the write (and the config redelivery it
          # would trigger on the agent).
          {:cont, {:ok, stats}}
        else
          case updater.(assignment, merged_params, actor) do
            {:ok, _updated} -> {:cont, {:ok, %{stats | updated: stats.updated + 1}}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end
    )
  end

  defp assignment_updater(opts) do
    case Keyword.get(opts, :assignment_updater) do
      fun when is_function(fun, 3) ->
        fun

      _ ->
        fn %AddonAssignment{} = assignment, params, actor ->
          assignment
          |> Ash.Changeset.for_update(:update, %{params: params}, actor: actor)
          |> Ash.update(actor: actor)
        end
    end
  end

  defp profile_id(%AddonProfile{id: id}), do: id
  defp profile_id(%{id: id}), do: id
  defp profile_id(%{"id" => id}), do: id
  defp profile_id(_profile), do: nil

  defp assignment_agent_uid(%AddonAssignment{agent_uid: agent_uid}), do: agent_uid
  defp assignment_agent_uid(%{agent_uid: agent_uid}), do: agent_uid
  defp assignment_agent_uid(%{"agent_uid" => agent_uid}), do: agent_uid
  defp assignment_agent_uid(_assignment), do: nil

  defp assignment_params(%AddonAssignment{params: params}) when is_map(params), do: params
  defp assignment_params(%{params: params}) when is_map(params), do: params
  defp assignment_params(%{"params" => params}) when is_map(params), do: params
  defp assignment_params(_assignment), do: %{}

  # Default: rely on the periodic `AddonProfileReconcileWorker` to propagate the
  # updated params. A caller may inject `:reconcile_fun` (arity 2) to force an
  # immediate per-profile reconcile.
  defp maybe_reconcile(profiles, opts, actor) do
    case Keyword.get(opts, :reconcile_fun) do
      fun when is_function(fun, 2) ->
        Enum.each(profiles, &fun.(&1, actor))
        :ok

      _ ->
        :ok
    end
  end

  # Per-run delivery heartbeat (freshness-tripwire contract). The
  # `SeasonalBaselineFreshnessWorker` judges delivery liveness by the RECENCY
  # of this health event, so a row must land on EVERY successful run —
  # `HealthTracker.record_health_check/3` dedupes unchanged states, which
  # would freeze the recency signal while the producer stays healthy, so the
  # (idempotent) healthy state change is recorded directly. Best-effort: a
  # failed heartbeat write never fails a reconcile whose delivery writes
  # already succeeded.
  defp record_heartbeat(summary, opts) do
    recorder = Keyword.get(opts, :heartbeat_recorder, &default_heartbeat_recorder/1)

    failed_sources = Map.get(summary, :failed_sources, [])

    recorder.(%{
      profiles: summary.profiles_total,
      assignments: summary.assignments_total,
      profiles_updated: summary.profiles_updated,
      assignments_updated: summary.assignments_updated,
      series: summary.series,
      healthy: failed_sources == [],
      failed_sources: failed_sources
    })

    :ok
  rescue
    error ->
      Logger.warning("Failed to record seasonal edge baseline heartbeat",
        check: @heartbeat_check_id,
        reason: inspect(error)
      )

      :ok
  end

  # A partial run (some source failed) records an UNHEALTHY heartbeat: the
  # freshness tripwire only trusts healthy ones, so it still fires, and the
  # health event now says which sources failed instead of going silent.
  defp default_heartbeat_recorder(metadata) do
    {new_state, reason} =
      if Map.get(metadata, :healthy, true),
        do: {:healthy, :heartbeat},
        else: {:unhealthy, :partial_delivery}

    case HealthTracker.record_state_change(:core, @heartbeat_check_id,
           old_state: :healthy,
           new_state: new_state,
           reason: reason,
           metadata: metadata
         ) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to record seasonal edge baseline heartbeat",
          check: @heartbeat_check_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp run_opts(%Oban.Job{}), do: []

  defp emit_delivery_telemetry(delivery) do
    stats = delivery.stats

    measurements =
      Map.take(stats, [
        :global_series,
        :scoped_series,
        :interface_sources,
        :interface_candidates,
        :scope_dropped,
        :topk_dropped,
        :cap_dropped,
        :quality_dropped
      ])

    :telemetry.execute(@delivery_telemetry, measurements, %{result: :ok})

    if stats.cap_dropped > 0 do
      Logger.warning("Seasonal edge baseline delivery truncated",
        cap_dropped: stats.cap_dropped,
        scoped_series: stats.scoped_series
      )
    end

    :ok
  end

  defp int_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp float_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_float(value) and value >= 0.0 and value <= 1.0 ->
        value

      value when is_integer(value) and value in 0..1 ->
        value * 1.0

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} when parsed >= 0.0 and parsed <= 1.0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp string_value(row, keys) when is_map(row) do
    Enum.find_value(keys, fn key ->
      case get(row, key) do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: nil, else: value

        _ ->
          nil
      end
    end)
  end

  defp number_value(value) when is_number(value), do: value * 1.0

  defp number_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp number_value(_value), do: nil

  defp get(row, key) when is_map(row) do
    Map.get(row, key, Map.get(row, to_string(key)))
  end
end
