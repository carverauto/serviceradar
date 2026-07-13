defmodule ServiceRadar.Observability.CapacityForecastConfig do
  @moduledoc """
  Deployment-level capacity forecasting tuning.

  This singleton stores the forecast horizon, warning threshold, model choice,
  and class-specific overrides used by the scheduled capacity forecasting job.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Observability.CapacityForecasting.Source

  @manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                 permission: "observability.alerts.manage"}
  @fields [
    :forecast_horizon_seconds,
    :warning_horizon_seconds,
    :warning_threshold_percent,
    :model,
    :minimum_history_points,
    :metric_class_overrides,
    :default_source_opt_ins
  ]
  @default_metric_class_overrides %{
    "interface" => %{},
    "cpu" => %{},
    "memory" => %{},
    "disk" => %{},
    "flow" => %{}
  }

  postgres do
    table "capacity_forecast_configs"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :warning_horizon_seconds, "capacity_forecast_configs_horizon_check",
        check:
          "forecast_horizon_seconds >= 3600 AND warning_horizon_seconds >= 3600 AND warning_horizon_seconds <= forecast_horizon_seconds",
        message: "must be less than or equal to forecast horizon"
    end
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
  end

  actions do
    defaults [:read]

    read :get_singleton do
      description "Get the singleton capacity forecast configuration"
      get? true
      filter expr(key == "default")
    end

    create :create do
      description "Create capacity forecast configuration"
      accept @fields
      change set_attribute(:key, "default")
    end

    update :update do
      description "Update capacity forecast configuration"
      accept @fields
      # The opt-in subset validation runs in-process; the singleton row does
      # not need an atomic update.
      require_atomic? false
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@manage_check)
    action_with_permission([:create, :update], @manage_check)
  end

  validations do
    validate compare(:warning_horizon_seconds,
               less_than_or_equal_to: {:ref, :forecast_horizon_seconds}
             ),
             message: "must be less than or equal to forecast horizon"

    validate fn changeset, _context ->
      validate_source_opt_ins(changeset)
    end
  end

  attributes do
    attribute :key, :string do
      allow_nil? false
      default "default"
      primary_key? true
      public? false
    end

    attribute :forecast_horizon_seconds, :integer do
      allow_nil? false
      default 7_776_000
      public? true
      constraints min: 3_600, max: 63_115_200
      description "Projection horizon for capacity forecasts"
    end

    attribute :warning_horizon_seconds, :integer do
      allow_nil? false
      default 2_592_000
      public? true
      constraints min: 3_600, max: 63_115_200
      description "Emit warnings when exhaustion is projected inside this horizon"
    end

    attribute :warning_threshold_percent, :float do
      allow_nil? false
      default 80.0
      public? true
      constraints min: 1.0, max: 100.0
      description "Utilization percentage treated as capacity exhaustion for forecasts"
    end

    attribute :model, :atom do
      allow_nil? false
      default :linear
      public? true
      constraints one_of: [:linear, :seasonal_linear, :holt_winters]
      description "Forecast model identifier"
    end

    attribute :minimum_history_points, :integer do
      allow_nil? false
      default 72
      public? true
      constraints min: 2, max: 35_040
      description "Minimum aggregate samples required before producing a forecast"
    end

    attribute :metric_class_overrides, :map do
      allow_nil? false
      default @default_metric_class_overrides
      public? true

      description "Per-metric-class forecast overrides keyed by interface, cpu, memory, disk, or flow"
    end

    attribute :default_source_opt_ins, {:array, :string} do
      allow_nil? false
      default []
      public? true

      description "Bursty forecast sources opted in beyond the monotone defaults (cpu_usage, interface_rate, flow_bytes_per_hour)"
    end

    timestamps()
  end

  # memory_usage and disk_usage always forecast; only the bursty sources the
  # worker excludes by default are valid opt-ins (Settings UI contract).
  defp validate_source_opt_ins(changeset) do
    case Ash.Changeset.fetch_change(changeset, :default_source_opt_ins) do
      {:ok, opt_ins} when is_list(opt_ins) ->
        allowed = Source.opt_in_names()

        case Enum.reject(opt_ins, &(&1 in allowed)) do
          [] ->
            :ok

          unknown ->
            {:error,
             field: :default_source_opt_ins,
             message: "must be a subset of #{Enum.join(allowed, ", ")}",
             vars: [unknown: Enum.join(unknown, ", ")]}
        end

      _ ->
        :ok
    end
  end
end
