defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer do
  @moduledoc """
  Builds the per-series hour-of-week `seasonal_baselines` payload and delivers it
  to the edge anomaly add-on (OpenSpec task 2.6 — edge-baseline DELIVERY).

  `SeasonalDisposition.Worker` already pages the 168-bucket hour-of-week profile
  rows and emits central disposition verdicts. This sibling worker reuses that
  exact SRQL fetch + row hydration (`Worker.edge_baseline_rows/2`), reduces each
  source's rows to the compact `{center, scale}` summary via `EdgeBaseline.build/2`,
  and writes the merged payload into the anomaly `AddonProfile.params`
  (`"seasonal_baselines"`). The profile reconciler then propagates the params onto
  every matched `AddonAssignment`, and the agent delivers them to the add-on via
  `configure()` — so the edge detector deseasonalizes against the long-horizon
  central profile instead of only its short rolling window.

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
  `:profile_updater`, and `:reconcile_fun`; production uses the seasonal sources,
  `SRQLRunner`, and the Ash-backed `AddonProfile` read/update + reconcile.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable],
      keys: [:trigger]
    ]

  alias ServiceRadar.Actors.SystemActor
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
  @default_interface_top_k_per_device 16
  @default_interface_min_history_weeks 3
  @default_max_baselines_per_agent 1_000
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

  defp build_delivery(opts) do
    opts
    |> sources()
    |> Enum.reduce_while({:ok, empty_delivery()}, fn source, {:ok, acc} ->
      case source_delivery(source, opts) do
        {:ok, delivery} -> {:cont, {:ok, merge_delivery(acc, delivery)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, delivery} ->
        governed = govern_interface_candidates(delivery, opts)
        emit_delivery_telemetry(governed)
        {:ok, governed}

      other ->
        other
    end
  end

  @doc """
  Build the payload and deliver it. Host baselines are written onto every enabled
  anomaly `AddonProfile`'s profile params; interface baselines are written onto
  matching profile-owned `AddonAssignment.params` after the optional reconcile.
  Returns a summary map.
  """
  @spec reconcile(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:seasonal_edge_baseline_producer))

    with {:ok, delivery} <- build_delivery(opts),
         {:ok, profiles} <- load_profiles(opts, actor),
         {:ok, updated} <- update_profiles(profiles, delivery.global_baselines, opts, actor),
         :ok <- maybe_reconcile(updated, opts, actor),
         {:ok, assignment_summary} <- update_scoped_assignments(updated, delivery, opts, actor) do
      {:ok,
       %{
         series: delivery.stats.global_series + delivery.stats.scoped_series,
         global_series: delivery.stats.global_series,
         scoped_series: delivery.stats.scoped_series,
         scoped_agents: map_size(delivery.scoped_baselines),
         truncated_series: delivery.stats.cap_dropped,
         profiles_updated: length(updated),
         profiles_total: length(profiles),
         assignments_updated: assignment_summary.updated,
         assignments_total: assignment_summary.total
       }}
    end
  end

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
    case Worker.edge_baseline_rows(source, opts) do
      {:ok, rows} ->
        {:ok, keyed_delivery(source, rows, opts)}

      {:error, reason} ->
        Logger.warning("Edge baseline source fetch failed",
          source: source.name,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # `EdgeBaseline.build/2` groups by `row.series_key`, so rewrite rows to the
  # delivered edge-baseline lookup key before building. Host sources keep the
  # historical `<device_uid>|<metric_name>` key; interface sources include
  # `if_index` so separate ports on one device cannot collapse.
  defp keyed_delivery(%Source{resource_type: "interface"} = source, rows, opts) do
    candidates = interface_candidates(source, rows, opts)

    %{
      empty_delivery()
      | interface_candidates: candidates,
        stats: %{
          empty_delivery().stats
          | interface_sources: 1,
            interface_candidates: length(candidates)
        }
    }
  end

  defp keyed_delivery(%Source{} = source, rows, _opts) do
    baselines = keyed_baselines(source, rows, :buckets)

    %{
      empty_delivery()
      | global_baselines: baselines,
        stats: %{empty_delivery().stats | global_series: map_size(baselines)}
    }
  end

  defp keyed_baselines(%Source{} = source, rows, encoding) do
    rows
    |> Enum.map(&Map.put(&1, :series_key, seasonal_series_key(source, &1)))
    |> EdgeBaseline.build(source.robust_statistic, encoding: encoding)
  end

  defp seasonal_series_key(%Source{} = source, row) do
    device_uid = Map.get(row, :series_key)
    metric_name = source.wire_metric_name

    case {source.resource_type, Map.get(row, :if_index)} do
      {"interface", if_index} when is_integer(if_index) and if_index > 0 ->
        "#{device_uid}|#{metric_name}|#{if_index}"

      _ ->
        "#{device_uid}|#{metric_name}"
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
    end)
    |> Enum.group_by(&Map.get(&1, :series_key))
    |> Enum.flat_map(fn {series_key, group_rows} ->
      if history_ready?(group_rows, min_history_weeks) do
        payload =
          group_rows
          |> EdgeBaseline.build(source.robust_statistic, encoding: :compact_168)
          |> Map.get(series_key)

        case payload do
          nil ->
            []

          payload ->
            [
              %{
                series_key: series_key,
                baseline: payload,
                scope: interface_scope(group_rows),
                device_uid: group_value(group_rows, :device_uid),
                if_index: group_value(group_rows, :if_index),
                metric_name: source.wire_metric_name,
                traffic_score: traffic_score(group_rows),
                bucket_count: length(group_rows)
              }
            ]
        end
      else
        []
      end
    end)
  end

  defp history_ready?(rows, min_history_weeks) do
    Enum.all?(rows, fn row -> sample_count(row) >= min_history_weeks end)
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
    top_k = int_opt(opts, :interface_top_k_per_device, @default_interface_top_k_per_device)
    cap = int_opt(opts, :max_baselines_per_agent, @default_max_baselines_per_agent)
    candidates = delivery.interface_candidates

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
      stats: %{
        global_series: 0,
        scoped_series: 0,
        interface_sources: 0,
        interface_candidates: 0,
        scope_dropped: 0,
        topk_dropped: 0,
        cap_dropped: 0
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

  defp update_profiles(profiles, baselines, opts, actor) do
    updater = profile_updater(opts)

    Enum.reduce_while(profiles, {:ok, []}, fn profile, {:ok, acc} ->
      params = merge_params(profile_params(profile), baselines)

      case updater.(profile, params, actor) do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
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
  defp merge_params(params, baselines) when is_map(params) do
    Map.put(params, @params_key, baselines)
  end

  defp merge_params(_params, baselines), do: %{@params_key => baselines}

  defp profile_params(%AddonProfile{params: params}) when is_map(params), do: params
  defp profile_params(%{params: params}) when is_map(params), do: params
  defp profile_params(_profile), do: %{}

  defp update_scoped_assignments(profiles, delivery, opts, actor) do
    if delivery.stats.interface_sources > 0 or Keyword.has_key?(opts, :assignments_loader) do
      with {:ok, assignments} <- load_assignments(profiles, opts, actor) do
        update_assignments(assignments, delivery, opts, actor)
      end
    else
      {:ok, %{updated: 0, total: 0}}
    end
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
        params = merge_params(assignment_params(assignment), baselines)

        case updater.(assignment, params, actor) do
          {:ok, _updated} -> {:cont, {:ok, %{stats | updated: stats.updated + 1}}}
          {:error, reason} -> {:halt, {:error, reason}}
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
        :cap_dropped
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
