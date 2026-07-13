defmodule ServiceRadar.Observability.AnomalyConfigSeeder do
  @moduledoc """
  Seeds first-boot anomaly detection and capacity forecast config rows.

  Helm renders deployment defaults as environment variables. This seeder uses
  those values only when the singleton rows are missing, so later operator edits
  in CNPG are not overwritten by pod restarts or chart upgrades.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Observability.CapacityForecastConfig
  alias ServiceRadar.Observability.CapacityForecasting.Source

  require Logger

  @anomaly_default_overrides %{
    "cpu" => %{"drift_mode" => "deseasonalized_only"},
    "memory" => %{"drift_mode" => "deseasonalized_only"},
    "interface" => %{"drift_mode" => "deseasonalized_only"},
    "disk" => %{"drift_mode" => "off"},
    "icmp" => %{"drift_mode" => "off"},
    "other" => %{"drift_mode" => "off"},
    "red" => %{}
  }
  @anomaly_default_metric_denylist ["cpu.frequency_hz"]
  @anomaly_default_emission %{
    "cooldown_secs" => 300,
    "budget_per_tick" => 100,
    "episode_update_interval_secs" => 1_800,
    "reopen_cooldown_secs" => 600
  }
  @forecast_default_overrides %{
    "interface" => %{},
    "cpu" => %{},
    "memory" => %{},
    "disk" => %{},
    "flow" => %{}
  }
  @forecast_models [:linear, :seasonal_linear, :holt_winters]

  def seed_defaults do
    if repo_enabled?() do
      actor = SystemActor.system(:anomaly_config_seeder)
      opts = [actor: actor]

      ensure_anomaly_config(opts)
      ensure_forecast_config(opts)
    end
  end

  @doc false
  def anomaly_attrs_from_env(get_env \\ &System.get_env/1) do
    %{
      n_sigma: float_env(get_env, "SERVICERADAR_ANOMALY_N_SIGMA", 3.0, min: 0.1, max: 20.0),
      window_size: int_env(get_env, "SERVICERADAR_ANOMALY_WINDOW_SIZE", 300, min: 2, max: 86_400),
      window_duration_seconds:
        int_env(get_env, "SERVICERADAR_ANOMALY_WINDOW_DURATION_SECONDS", 900,
          min: 1,
          max: 86_400
        ),
      confirm_slots:
        int_env(get_env, "SERVICERADAR_ANOMALY_CONFIRM_SLOTS", 5, min: 1, max: 10_000),
      min_samples: int_env(get_env, "SERVICERADAR_ANOMALY_MIN_SAMPLES", 30, min: 1, max: 86_400),
      metric_class_overrides:
        map_env(
          get_env,
          "SERVICERADAR_ANOMALY_METRIC_CLASS_OVERRIDES_JSON",
          @anomaly_default_overrides
        ),
      metric_denylist:
        list_env(
          get_env,
          "SERVICERADAR_ANOMALY_METRIC_DENYLIST_JSON",
          @anomaly_default_metric_denylist
        ),
      emission:
        map_env(
          get_env,
          "SERVICERADAR_ANOMALY_EMISSION_JSON",
          @anomaly_default_emission
        )
    }
  end

  @doc false
  def forecast_attrs_from_env(get_env \\ &System.get_env/1) do
    # The resource validation allows exactly these opt-ins; other tokens would
    # fail it and abort the whole first-boot seed.
    opt_in_names = Source.opt_in_names()

    %{
      forecast_horizon_seconds:
        int_env(get_env, "SERVICERADAR_CAPACITY_FORECAST_CONFIG_HORIZON_SECONDS", 7_776_000,
          min: 3_600,
          max: 63_115_200
        ),
      warning_horizon_seconds:
        int_env(
          get_env,
          "SERVICERADAR_CAPACITY_FORECAST_CONFIG_WARNING_HORIZON_SECONDS",
          2_592_000,
          min: 3_600,
          max: 63_115_200
        ),
      warning_threshold_percent:
        float_env(
          get_env,
          "SERVICERADAR_CAPACITY_FORECAST_CONFIG_WARNING_THRESHOLD_PERCENT",
          80.0,
          min: 1.0,
          max: 100.0
        ),
      model: model_env(get_env, "SERVICERADAR_CAPACITY_FORECAST_CONFIG_MODEL", :linear),
      minimum_history_points:
        int_env(get_env, "SERVICERADAR_CAPACITY_FORECAST_CONFIG_MINIMUM_HISTORY_POINTS", 72,
          min: 2,
          max: 35_040
        ),
      metric_class_overrides:
        map_env(
          get_env,
          "SERVICERADAR_CAPACITY_FORECAST_CONFIG_METRIC_CLASS_OVERRIDES_JSON",
          @forecast_default_overrides
        ),
      default_source_opt_ins:
        get_env
        |> comma_list_env("SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS")
        |> Enum.filter(&(&1 in opt_in_names))
    }
  end

  defp ensure_anomaly_config(opts) do
    case AnomalyDetectionConfig.get_settings(opts) do
      {:ok, %AnomalyDetectionConfig{}} ->
        :ok

      {:ok, nil} ->
        create_anomaly_config(opts)

      {:error, reason} ->
        handle_settings_error(reason, &create_anomaly_config/1, opts, "anomaly detection")
    end
  end

  defp ensure_forecast_config(opts) do
    case CapacityForecastConfig.get_settings(opts) do
      {:ok, %CapacityForecastConfig{}} ->
        :ok

      {:ok, nil} ->
        create_forecast_config(opts)

      {:error, reason} ->
        handle_settings_error(reason, &create_forecast_config/1, opts, "capacity forecast")
    end
  end

  defp create_anomaly_config(opts) do
    case AnomalyDetectionConfig.create_settings(anomaly_attrs_from_env(), opts) do
      {:ok, _settings} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to seed anomaly detection config: #{inspect(reason)}")
    end
  end

  defp create_forecast_config(opts) do
    case CapacityForecastConfig.create_settings(forecast_attrs_from_env(), opts) do
      {:ok, _settings} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to seed capacity forecast config: #{inspect(reason)}")
    end
  end

  defp handle_settings_error(reason, create_fun, opts, label) do
    if not_found?(reason) do
      create_fun.(opts)
    else
      Logger.warning("Failed to load #{label} config: #{inspect(reason)}")
    end
  end

  defp int_env(get_env, name, default, bounds) do
    case get_env.(name) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0 -> clamp(parsed, bounds)
          _ -> default
        end

      _ ->
        default
    end
  end

  defp float_env(get_env, name, default, bounds) do
    case get_env.(name) do
      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0.0 -> clamp(parsed, bounds)
          _ -> default
        end

      _ ->
        default
    end
  end

  defp clamp(value, bounds) do
    value
    |> max(Keyword.fetch!(bounds, :min))
    |> min(Keyword.fetch!(bounds, :max))
  end

  # Helm renders `{}` for unset JSON map values; an empty object carries no
  # configuration, so seed the code defaults instead of storing it and
  # discarding the per-class defaults on fresh installs.
  defp map_env(get_env, name, default) do
    case get_env.(name) do
      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, parsed} when is_map(parsed) and map_size(parsed) > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp list_env(get_env, name, default) do
    case get_env.(name) do
      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, values} when is_list(values) ->
            values
            |> Enum.flat_map(fn
              value when is_binary(value) ->
                trimmed = String.trim(value)
                if trimmed == "", do: [], else: [trimmed]

              _ ->
                []
            end)
            |> Enum.uniq()

          _ ->
            default
        end

      _ ->
        default
    end
  end

  defp comma_list_env(get_env, name) do
    case get_env.(name) do
      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp model_env(get_env, name, default) do
    case get_env.(name) do
      value when is_binary(value) -> parse_model(value, default)
      _ -> default
    end
  end

  defp parse_model(value, default) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
    |> then(fn model -> if model in @forecast_models, do: model, else: default end)
  rescue
    ArgumentError -> default
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_), do: false
end
