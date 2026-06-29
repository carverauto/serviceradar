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
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @addon_id "anomaly"
  @params_key "seasonal_baselines"

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    case reconcile(run_opts(job)) do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Build the merged `seasonal_baselines` payload across every supported source.

  Returns `{:ok, %{"<device_uid>|<metric_name>" => %{"buckets" => [...]}}}`. A
  source with no profile rows contributes nothing; a query/fetch failure on any
  source aborts with `{:error, reason}` (a partial baseline would silently drop a
  metric's deseasonalization).
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts \\ []) do
    opts
    |> sources()
    |> Enum.reduce_while({:ok, %{}}, fn source, {:ok, acc} ->
      case source_baselines(source, opts) do
        {:ok, baselines} -> {:cont, {:ok, Map.merge(acc, baselines)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Build the payload and deliver it onto every enabled anomaly `AddonProfile`'s
  `params["seasonal_baselines"]`, then trigger a reconcile so matched assignments
  pick up the new params. Returns a summary map.
  """
  @spec reconcile(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:seasonal_edge_baseline_producer))

    with {:ok, baselines} <- build(opts),
         {:ok, profiles} <- load_profiles(opts, actor),
         {:ok, updated} <- update_profiles(profiles, baselines, opts, actor) do
      # Delivery to agents rides the existing periodic `AddonProfileReconcileWorker`
      # (~60s), which copies profile params onto matched assignments -> configure().
      # An injected `:reconcile_fun` lets a caller (or test) force it immediately.
      maybe_reconcile(updated, opts, actor)

      {:ok,
       %{
         series: map_size(baselines),
         profiles_updated: length(updated),
         profiles_total: length(profiles)
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

  defp source_baselines(%Source{} = source, opts) do
    case Worker.edge_baseline_rows(source, opts) do
      {:ok, rows} ->
        {:ok, keyed_baselines(source, rows)}

      {:error, reason} ->
        Logger.warning("Edge baseline source fetch failed",
          source: source.name,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # `EdgeBaseline.build/2` groups by the profile `series` (= central `series:uid` =
  # `device_id`). Re-key each series to the `<device_uid>|<metric_name>` the add-on
  # derives at scoring so the delivered baseline resolves. Two metrics on one
  # device (cpu/memory) therefore never collide in the flat delivered map.
  defp keyed_baselines(%Source{} = source, rows) do
    metric_name = source.wire_metric_name

    rows
    |> EdgeBaseline.build(source.robust_statistic)
    |> Map.new(fn {device_uid, baseline} ->
      {seasonal_series_key(device_uid, metric_name), baseline}
    end)
  end

  defp seasonal_series_key(device_uid, metric_name), do: "#{device_uid}|#{metric_name}"

  defp sources(opts) do
    sources =
      case Keyword.fetch(opts, :sources) do
        {:ok, sources} -> sources
        :error -> Source.defaults(opts)
      end

    sources
    |> Enum.map(&Source.from_config/1)
    |> Enum.filter(&Source.seasonal_disposition_supported?/1)
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

  # Default: rely on the periodic `AddonProfileReconcileWorker` to propagate the
  # updated params. A caller may inject `:reconcile_fun` (arity 2) to force an
  # immediate per-profile reconcile.
  defp maybe_reconcile(profiles, opts, actor) do
    case Keyword.get(opts, :reconcile_fun) do
      fun when is_function(fun, 2) -> Enum.each(profiles, &fun.(&1, actor))
      _ -> :ok
    end
  end

  defp run_opts(%Oban.Job{}), do: []
end
