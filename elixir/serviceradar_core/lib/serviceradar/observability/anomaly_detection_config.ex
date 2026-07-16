defmodule ServiceRadar.Observability.AnomalyDetectionConfig do
  @moduledoc """
  Deployment-level anomaly detection tuning.

  This singleton stores the default detector parameters and class-specific
  overrides that later hot-reload phases will apply to live per-series context.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                 permission: "observability.alerts.manage"}
  @fields [
    :n_sigma,
    :window_size,
    :window_duration_seconds,
    :confirm_slots,
    :min_samples,
    :metric_class_overrides,
    :metric_denylist,
    :emission
  ]
  @default_metric_class_overrides %{
    "cpu" => %{"drift_mode" => "deseasonalized_only"},
    "memory" => %{"drift_mode" => "deseasonalized_only"},
    "interface" => %{
      "drift_mode" => "deseasonalized_only"
    },
    "disk" => %{"drift_mode" => "off"},
    "icmp" => %{"drift_mode" => "off"},
    "other" => %{"drift_mode" => "off"},
    "red" => %{}
  }
  @default_metric_denylist ["cpu.frequency_hz"]
  @default_emission %{
    "cooldown_secs" => 300,
    "budget_per_tick" => 100,
    "episode_update_interval_secs" => 1_800,
    "reopen_cooldown_secs" => 600
  }

  @doc """
  Default edge episode heartbeat interval (seconds), from the emission
  defaults. Workers that derive margins from the heartbeat (e.g. the episode
  stale-close sweep) use this instead of duplicating the constant.
  """
  @spec default_episode_update_interval_secs() :: pos_integer()
  def default_episode_update_interval_secs do
    Map.fetch!(@default_emission, "episode_update_interval_secs")
  end

  postgres do
    table "anomaly_detection_configs"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :min_samples, "anomaly_detection_configs_window_check",
        check:
          "window_size >= 2 AND window_duration_seconds >= 1 AND min_samples >= 1 AND min_samples <= window_size",
        message: "must be less than or equal to window size"
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
      description "Get the singleton anomaly detection configuration"
      get? true
      filter expr(key == "default")
    end

    create :create do
      description "Create anomaly detection configuration"
      accept @fields
      change set_attribute(:key, "default")
    end

    update :update do
      description "Update anomaly detection configuration"
      accept @fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@manage_check)
    action_with_permission([:create, :update], @manage_check)
  end

  validations do
    validate compare(:min_samples, less_than_or_equal_to: {:ref, :window_size}),
      message: "must be less than or equal to window size"
  end

  attributes do
    attribute :key, :string do
      allow_nil? false
      default "default"
      primary_key? true
      public? false
    end

    attribute :n_sigma, :float do
      allow_nil? false
      default 3.0
      public? true
      constraints min: 0.1, max: 20.0
      description "Z-score threshold used to classify an evaluation slot as anomalous"
    end

    attribute :window_size, :integer do
      allow_nil? false
      default 300
      public? true
      constraints min: 2, max: 86_400
      description "Maximum samples retained in the rolling baseline window"
    end

    attribute :window_duration_seconds, :integer do
      allow_nil? false
      default 900
      public? true
      constraints min: 1, max: 86_400

      description "Operator target duration for baseline planning; edge scoring uses window_size samples"
    end

    attribute :confirm_slots, :integer do
      allow_nil? false
      default 5
      public? true
      constraints min: 1, max: 10_000
      description "Consecutive anomalous slots required before emitting a finding"
    end

    attribute :min_samples, :integer do
      allow_nil? false
      default 30
      public? true
      constraints min: 1, max: 86_400
      description "Minimum clean baseline samples required before findings may emit"
    end

    attribute :metric_class_overrides, :map do
      allow_nil? false
      default @default_metric_class_overrides
      public? true

      description "Per-metric-class edge detector overrides keyed by cpu, memory, disk, interface, icmp, or other"
    end

    attribute :metric_denylist, {:array, :string} do
      allow_nil? false
      default @default_metric_denylist
      public? true
      description "Metric names that should not produce edge detector findings"
    end

    attribute :emission, :map do
      allow_nil? false
      default @default_emission
      public? true
      description "Edge emission governance knobs projected into anomaly add-on managed params"
    end

    timestamps()
  end
end
