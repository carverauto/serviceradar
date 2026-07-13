defmodule ServiceRadar.Observability.AnomalyConfigRuntime do
  @moduledoc """
  Periodically refreshes anomaly and capacity-forecast tuning from CNPG.

  Streaming anomaly evaluation reads from this cache instead of querying Ash per
  sample. The cache is refreshed on a timer so settings UI edits take effect
  without a detector restart.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Observability.CapacityForecastConfig

  require Logger

  @anomaly_runtime_override_keys ~w(n_sigma window_size confirm_slots min_samples)
  @cache_key {__MODULE__, :settings}
  @default_refresh_ms 30_000
  defstruct [
    :anomaly_fetcher,
    :forecast_fetcher,
    :refresh_interval_ms
  ]

  @type cache :: %{
          optional(:anomaly_series_config) => map(),
          optional(:capacity_forecasting_opts) => keyword(),
          optional(:seasonal_disposition_opts) => keyword(),
          optional(:refreshed_at_ms) => integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec anomaly_series_config() :: map()
  def anomaly_series_config do
    Map.get(cache(), :anomaly_series_config, %{})
  end

  @spec capacity_forecasting_opts() :: keyword()
  def capacity_forecasting_opts do
    cache()
    |> Map.get(:capacity_forecasting_opts, [])
    |> Keyword.new()
  end

  @doc """
  Hot-reloadable tuning for the central-seasonal disposition worker.

  Shares the anomaly-detection settings (`n_sigma`, `confirm_slots`, the per-metric-
  class overrides) so the seasonal tier tracks the same operator-facing tuning as
  the streaming detector; mapped to the seasonal NIF config keys the worker reads.
  """
  @spec seasonal_disposition_opts() :: keyword()
  def seasonal_disposition_opts do
    cache()
    |> Map.get(:seasonal_disposition_opts, [])
    |> Keyword.new()
  end

  @spec refresh(GenServer.server()) :: {:ok, cache()}
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @doc false
  @spec put_cache_for_test(cache()) :: :ok
  def put_cache_for_test(%{} = cache) do
    :persistent_term.put(@cache_key, normalize_cache(cache))
  end

  @doc false
  @spec clear_cache_for_test() :: :ok
  def clear_cache_for_test do
    :persistent_term.erase(@cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec anomaly_series_config_from_settings(struct() | nil) :: map()
  def anomaly_series_config_from_settings(nil), do: %{}

  def anomaly_series_config_from_settings(%AnomalyDetectionConfig{} = settings) do
    base = %{
      "n_sigma" => settings.n_sigma,
      "window_size" => settings.window_size,
      "confirm_slots" => settings.confirm_slots,
      "min_samples" => settings.min_samples
    }

    overrides = normalize_metric_class_overrides(settings.metric_class_overrides || %{})

    metric_class_defaults =
      overrides
      |> Enum.filter(fn {_class, values} -> map_size(values) > 0 end)
      |> Map.new(fn {class, values} ->
        {class, Map.merge(base, Map.take(values, @anomaly_runtime_override_keys))}
      end)
      |> Map.put("default", base)

    %{metric_class_defaults: metric_class_defaults}
  end

  @doc false
  @spec seasonal_disposition_opts_from_settings(struct() | nil) :: keyword()
  def seasonal_disposition_opts_from_settings(nil), do: []

  def seasonal_disposition_opts_from_settings(%AnomalyDetectionConfig{} = settings) do
    [
      seasonal_n_sigma: settings.n_sigma,
      min_bucket_samples: settings.min_samples,
      confirm_slots: settings.confirm_slots,
      seasonal_metric_class_overrides:
        normalize_metric_class_overrides(settings.metric_class_overrides || %{})
    ]
  end

  @doc false
  @spec capacity_forecasting_opts_from_settings(struct() | nil) :: keyword()
  def capacity_forecasting_opts_from_settings(nil), do: []

  def capacity_forecasting_opts_from_settings(%CapacityForecastConfig{} = settings) do
    [
      horizon_seconds: settings.forecast_horizon_seconds,
      warning_horizon_seconds: settings.warning_horizon_seconds,
      warning_threshold_percent: settings.warning_threshold_percent,
      min_points: settings.minimum_history_points,
      capacity_metric_class_overrides:
        normalize_metric_class_overrides(settings.metric_class_overrides || %{})
    ]
    |> maybe_put_forecast_model(settings.model)
    |> maybe_put_source_opt_ins(settings.default_source_opt_ins)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      anomaly_fetcher: Keyword.get(opts, :anomaly_fetcher, &fetch_anomaly_settings/1),
      forecast_fetcher: Keyword.get(opts, :forecast_fetcher, &fetch_forecast_settings/1),
      refresh_interval_ms:
        Keyword.get(opts, :refresh_interval_ms) ||
          Application.get_env(
            :serviceradar_core,
            :anomaly_config_runtime_refresh_ms,
            @default_refresh_ms
          )
    }

    {:ok, cache} = refresh_cache(state)
    schedule_refresh(state)

    {:ok,
     %{state | refresh_interval_ms: positive_int(state.refresh_interval_ms, @default_refresh_ms)},
     {:continue, {:refreshed, cache}}}
  end

  @impl true
  def handle_continue({:refreshed, _cache}, state), do: {:noreply, state}

  @impl true
  def handle_call(:refresh, _from, state) do
    {:ok, cache} = refresh_cache(state)
    {:reply, {:ok, cache}, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {:ok, _cache} = refresh_cache(state)
    schedule_refresh(state)
    {:noreply, state}
  end

  defp refresh_cache(state) do
    actor = SystemActor.system(:anomaly_config_runtime)
    existing = cache()

    anomaly_settings =
      case state.anomaly_fetcher.(actor) do
        {:ok, %AnomalyDetectionConfig{} = settings} ->
          {:ok, settings}

        {:ok, nil} ->
          :unchanged

        {:error, reason} ->
          Logger.warning("Failed to refresh anomaly detection config",
            reason: inspect(reason)
          )

          :unchanged
      end

    anomaly_series_config =
      case anomaly_settings do
        {:ok, settings} -> anomaly_series_config_from_settings(settings)
        :unchanged -> Map.get(existing, :anomaly_series_config, %{})
      end

    seasonal_disposition_opts =
      case anomaly_settings do
        {:ok, settings} -> seasonal_disposition_opts_from_settings(settings)
        :unchanged -> Map.get(existing, :seasonal_disposition_opts, [])
      end

    capacity_forecasting_opts =
      case state.forecast_fetcher.(actor) do
        {:ok, %CapacityForecastConfig{} = settings} ->
          capacity_forecasting_opts_from_settings(settings)

        {:ok, nil} ->
          Map.get(existing, :capacity_forecasting_opts, [])

        {:error, reason} ->
          Logger.warning("Failed to refresh capacity forecast config",
            reason: inspect(reason)
          )

          Map.get(existing, :capacity_forecasting_opts, [])
      end

    cache =
      normalize_cache(%{
        anomaly_series_config: anomaly_series_config,
        capacity_forecasting_opts: capacity_forecasting_opts,
        seasonal_disposition_opts: seasonal_disposition_opts,
        refreshed_at_ms: System.monotonic_time(:millisecond)
      })

    :persistent_term.put(@cache_key, cache)
    {:ok, cache}
  rescue
    error ->
      Logger.warning("Failed to refresh anomaly config runtime cache",
        reason: Exception.message(error)
      )

      {:ok, cache()}
  end

  defp fetch_anomaly_settings(actor) do
    AnomalyDetectionConfig.get_settings(actor: actor)
  end

  defp fetch_forecast_settings(actor) do
    CapacityForecastConfig.get_settings(actor: actor)
  end

  defp cache do
    :persistent_term.get(@cache_key, %{})
  end

  defp normalize_cache(cache) do
    %{
      anomaly_series_config: Map.get(cache, :anomaly_series_config, %{}),
      capacity_forecasting_opts:
        cache
        |> Map.get(:capacity_forecasting_opts, [])
        |> Keyword.new(),
      seasonal_disposition_opts:
        cache
        |> Map.get(:seasonal_disposition_opts, [])
        |> Keyword.new(),
      refreshed_at_ms: Map.get(cache, :refreshed_at_ms, System.monotonic_time(:millisecond))
    }
  end

  defp normalize_metric_class_overrides(overrides) when is_map(overrides) do
    Map.new(overrides, fn {class, values} ->
      {normalize_metric_class(class), normalize_override_values(values)}
    end)
  end

  defp normalize_metric_class_overrides(_overrides), do: %{}

  defp normalize_metric_class(class) when is_atom(class), do: Atom.to_string(class)
  defp normalize_metric_class(class), do: to_string(class)

  defp normalize_override_values(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_override_values(_values), do: %{}

  defp maybe_put_forecast_model(opts, model)
       when model in [:linear, :seasonal_linear, :holt_winters],
       do: Keyword.put(opts, :forecast_model, Atom.to_string(model))

  defp maybe_put_forecast_model(opts, _model), do: opts

  # DB-derived opts override the env-derived worker config when the worker
  # merges runtime opts, so the DB opt-in list is forwarded only when an
  # operator actually selected sources; a default-empty row would otherwise
  # permanently mask env opt-ins (design D8: DB wins when non-empty, else env).
  defp maybe_put_source_opt_ins(opts, [_ | _] = opt_ins),
    do: Keyword.put(opts, :default_source_opt_ins, Enum.map(opt_ins, &to_string/1))

  defp maybe_put_source_opt_ins(opts, _opt_ins), do: opts

  defp schedule_refresh(%{refresh_interval_ms: refresh_interval_ms}) do
    Process.send_after(self(), :refresh, positive_int(refresh_interval_ms, @default_refresh_ms))
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
