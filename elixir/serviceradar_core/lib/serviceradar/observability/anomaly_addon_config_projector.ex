defmodule ServiceRadar.Observability.AnomalyAddonConfigProjector do
  @moduledoc """
  Projects operator anomaly settings into the edge anomaly add-on profile.

  The Settings UI writes the `AnomalyDetectionConfig` singleton. Central workers
  read it directly through `AnomalyConfigRuntime`, but edge add-ons only receive
  configuration through profile/assignment params. This worker writes the
  settings-derived edge subset into `params["managed"]`, leaving top-level
  operator profile params and delivered `seasonal_baselines` untouched.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query

  @addon_id "anomaly"
  @managed_key "managed"
  @removed_top_level_param_keys ~w(cusum_enabled)
  @edge_metric_class_keys MapSet.new(~w(
    enabled
    drift_mode
    cusum_k
    cusum_h
    h_confirm_mult
    drift_confirm_window
    drift_clear_slots
    drift_min_effect
    drift_adopt_after_samples
    spike_adopt_after_samples
    drift_escalate_after_secs
    min_std_floor
    min_cv
    drift_min_cv
    abs_effect_floor
    burst_envelope_enabled
    burst_envelope_quantile
    burst_envelope_multiplier
    burst_envelope_lag_samples
    burst_envelope_min_samples
    severity_cap
    severity_bands
  ))
  @edge_emission_keys MapSet.new(~w(
    cooldown_secs
    budget_per_tick
    episode_update_interval_secs
    reopen_cooldown_secs
  ))
  @telemetry [:serviceradar, :anomaly_detection, :edge_config_projection]

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    case reconcile(run_opts(job)) do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Project the Settings singleton into enabled anomaly add-on profiles.

  Test callers can inject `:settings_fetcher`, `:profiles_loader`, and
  `:profile_updater` to exercise the merge contract without a database.
  """
  @spec reconcile(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:anomaly_addon_config_projector))

    with {:ok, settings} <- fetch_settings(opts, actor),
         managed = managed_params_from_settings(settings),
         {:ok, profiles} <- load_profiles(opts, actor),
         {:ok, summary} <- update_profiles(profiles, managed, opts, actor),
         :ok <- maybe_reconcile(summary.updated_profiles, opts, actor) do
      result =
        summary
        |> Map.delete(:updated_profiles)
        |> Map.merge(%{
          managed_keys: managed |> Map.keys() |> Enum.sort(),
          projected?: map_size(managed) > 0
        })

      emit_telemetry(result)
      {:ok, result}
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

  @doc false
  @spec managed_params_from_settings(AnomalyDetectionConfig.t() | nil) :: map()
  def managed_params_from_settings(nil), do: %{}

  def managed_params_from_settings(%AnomalyDetectionConfig{} = settings) do
    %{}
    |> put_present("n_sigma", settings.n_sigma)
    |> put_present("window_size", settings.window_size)
    |> put_present("confirm_slots", settings.confirm_slots)
    |> put_present("min_samples", settings.min_samples)
    |> maybe_put_metric_denylist(settings.metric_denylist)
    |> maybe_put_emission(settings.emission || %{})
    |> maybe_put_metric_classes(settings.metric_class_overrides || %{})
  end

  defp fetch_settings(opts, actor) do
    case Keyword.get(opts, :settings_fetcher) do
      fetcher when is_function(fetcher, 1) ->
        fetcher.(actor)

      _ ->
        AnomalyDetectionConfig.get_settings(actor: actor)
    end
  end

  defp load_profiles(opts, actor) do
    case Keyword.get(opts, :profiles_loader) do
      loader when is_function(loader, 1) ->
        loader.(actor)

      _ ->
        AddonProfile
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(addon_id == ^@addon_id and enabled == true)
        |> Ash.Query.load(:addon_package)
        |> Ash.read(actor: actor)
    end
  end

  defp update_profiles(profiles, managed, opts, actor) do
    updater = profile_updater(opts)

    Enum.reduce_while(
      profiles,
      {:ok,
       %{
         profiles_total: length(profiles),
         profiles_updated: 0,
         profiles_unchanged: 0,
         updated_profiles: []
       }},
      fn profile, {:ok, stats} ->
        current_params = profile_params(profile)
        next_params = merge_params(current_params, managed_for_profile(managed, profile))

        if current_params == next_params do
          {:cont, {:ok, %{stats | profiles_unchanged: stats.profiles_unchanged + 1}}}
        else
          case updater.(profile, next_params, actor) do
            {:ok, updated} ->
              {:cont,
               {:ok,
                %{
                  stats
                  | profiles_updated: stats.profiles_updated + 1,
                    updated_profiles: [updated | stats.updated_profiles]
                }}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end
      end
    )
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

  defp merge_params(params, managed) when is_map(params) do
    params
    |> stringify_keys()
    |> Map.drop(@removed_top_level_param_keys)
    |> Map.put(@managed_key, managed)
  end

  defp merge_params(_params, managed), do: %{@managed_key => managed}

  # Add-on profile writes are validated against the schema stored with the
  # assigned package, which can lag the binary during a rolling upgrade. Keep
  # a 0.2 profile writable by projecting only the managed keys its stored
  # schema admits. Once the package is upgraded, the next reconciliation adds
  # the newly supported settings automatically.
  defp managed_for_profile(managed, profile) do
    case managed_schema(profile) do
      nil -> managed
      schema -> project_schema_value(managed, schema)
    end
  end

  defp managed_schema(profile) do
    package = Map.get(profile, :addon_package) || Map.get(profile, "addon_package")

    schema =
      if is_map(package) do
        Map.get(package, :config_schema) || Map.get(package, "config_schema")
      end

    if is_map(schema) do
      properties = Map.get(schema, "properties") || Map.get(schema, :properties)

      if is_map(properties) do
        Map.get(properties, @managed_key) || Map.get(properties, :managed)
      end
    end
  end

  defp project_schema_value(value, schema) when is_map(value) and is_map(schema) do
    properties = Map.get(schema, "properties") || Map.get(schema, :properties)
    additional = additional_properties(schema)

    cond do
      is_map(properties) ->
        Enum.reduce(value, %{}, fn {key, child_value}, acc ->
          key = to_string(key)

          child_schema =
            Map.get(properties, key) ||
              case additional do
                %{} = schema -> schema
                true -> %{}
                _ -> nil
              end

          if is_nil(child_schema) do
            acc
          else
            Map.put(acc, key, project_schema_value(child_value, child_schema))
          end
        end)

      is_map(additional) ->
        Map.new(value, fn {key, child_value} ->
          {to_string(key), project_schema_value(child_value, additional)}
        end)

      additional == false ->
        %{}

      true ->
        value
    end
  end

  defp project_schema_value(value, _schema), do: value

  defp additional_properties(schema) do
    cond do
      Map.has_key?(schema, "additionalProperties") -> Map.fetch!(schema, "additionalProperties")
      Map.has_key?(schema, :additionalProperties) -> Map.fetch!(schema, :additionalProperties)
      true -> true
    end
  end

  defp profile_params(%AddonProfile{params: params}) when is_map(params),
    do: stringify_keys(params)

  defp profile_params(%{params: params}) when is_map(params), do: stringify_keys(params)
  defp profile_params(%{"params" => params}) when is_map(params), do: stringify_keys(params)
  defp profile_params(_profile), do: %{}

  defp maybe_reconcile(profiles, opts, actor) do
    case Keyword.get(opts, :reconcile_fun) do
      fun when is_function(fun, 2) ->
        Enum.each(profiles, &fun.(&1, actor))
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_put_metric_classes(params, overrides) do
    classes =
      overrides
      |> normalize_metric_class_overrides()
      |> Enum.reject(fn {_class, values} -> map_size(values) == 0 end)
      |> Map.new()

    if map_size(classes) > 0, do: Map.put(params, "metric_classes", classes), else: params
  end

  defp maybe_put_metric_denylist(params, denylist) when is_list(denylist) do
    denylist =
      denylist
      |> Enum.flat_map(fn
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: [], else: [trimmed]

        _ ->
          []
      end)
      |> Enum.uniq()

    Map.put(params, "metric_denylist", denylist)
  end

  defp maybe_put_metric_denylist(params, _denylist), do: params

  defp maybe_put_emission(params, emission) when is_map(emission) do
    emission =
      emission
      |> Enum.flat_map(fn {key, value} ->
        key = to_string(key)

        if MapSet.member?(@edge_emission_keys, key) and not is_nil(value) do
          [{key, normalize_value(value)}]
        else
          []
        end
      end)
      |> Map.new()

    if map_size(emission) > 0, do: Map.put(params, "emission", emission), else: params
  end

  defp maybe_put_emission(params, _emission), do: params

  defp normalize_metric_class_overrides(overrides) when is_map(overrides) do
    Map.new(overrides, fn {class, values} ->
      {to_string(class), normalize_metric_class_values(values)}
    end)
  end

  defp normalize_metric_class_overrides(_overrides), do: %{}

  defp normalize_metric_class_values(values) when is_map(values) do
    values
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      if MapSet.member?(@edge_metric_class_keys, key) and not is_nil(value) do
        case normalize_metric_class_value(key, value) do
          {:ok, normalized} -> [{key, normalized}]
          :drop -> []
        end
      else
        []
      end
    end)
    |> Map.new()
  end

  defp normalize_metric_class_values(_values), do: %{}

  # `drift_mode` is a string enum in the add-on schema, but settings rows
  # seeded from unquoted Helm chart defaults carry YAML 1.1 booleans
  # (`drift_mode: off` parses as `false`, `drift_mode: on` as `true`).
  # Coerce the legacy `false` back to `"off"` and drop the legacy `true`,
  # which has no valid string form. Every other value passes through
  # untouched so a misspelled mode fails loudly at profile validation
  # instead of being silently discarded.
  defp normalize_metric_class_value("drift_mode", false), do: {:ok, "off"}

  defp normalize_metric_class_value("drift_mode", true), do: :drop

  defp normalize_metric_class_value(_key, value), do: {:ok, normalize_value(value)}

  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  defp stringify_keys(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp emit_telemetry(summary) do
    :telemetry.execute(
      @telemetry,
      Map.take(summary, [:profiles_total, :profiles_updated, :profiles_unchanged]),
      %{projected?: summary.projected?}
    )
  end

  defp run_opts(%Oban.Job{}), do: []
end
