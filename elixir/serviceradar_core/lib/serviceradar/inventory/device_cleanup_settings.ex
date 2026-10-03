defmodule ServiceRadar.Inventory.DeviceCleanupSettings do
  @moduledoc """
  Instance-level settings for device cleanup retention.

  This resource stores the retention window and schedule used by the
  device cleanup worker to purge tombstoned devices, the window after
  which ephemeral devices (no strong identifier) are expired
  (`ServiceRadar.Inventory.EphemeralDeviceExpiry`), and the rules that retire
  a source-authoritative identifier its source stopped reporting
  (`ServiceRadar.Inventory.Identity.SourceRetirement`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  alias ServiceRadar.Inventory.Validations.EphemeralExpiryExclusionQuery

  @settings_fields [
    :retention_days,
    :cleanup_interval_minutes,
    :batch_size,
    :enabled,
    :ephemeral_expiry_enabled,
    :ephemeral_expiry_days,
    :ephemeral_expiry_exclusion_query,
    :ephemeral_expiry_max_fraction,
    :ephemeral_expiry_guard_override,
    :source_retirement_enabled,
    :source_retirement_absent_collections,
    :source_retirement_min_absence_hours,
    :source_retirement_max_fraction,
    :source_retirement_guard_override,
    :source_retired_grace_days,
    :max_successions_per_run
  ]

  postgres do
    table "device_cleanup_settings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  json_api do
    type "device_cleanup_settings"

    routes do
      base "/device-cleanup-settings"

      get :get_singleton, route: "/"
      post :create
      patch :update
    end
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
    define :run_cleanup, action: :run_cleanup
  end

  actions do
    defaults [:read]

    read :get_singleton do
      description "Get the singleton cleanup settings"
      get? true
      filter expr(key == "default")
    end

    create :create do
      description "Create device cleanup settings"
      accept @settings_fields
      change set_attribute(:key, "default")
      validate EphemeralExpiryExclusionQuery
    end

    update :update do
      description "Update device cleanup settings"
      accept @settings_fields
      validate EphemeralExpiryExclusionQuery
    end

    action :run_cleanup do
      description "Enqueue an immediate device cleanup run"
      returns :map

      run fn _input, context ->
        actor = context.actor

        case ServiceRadar.Inventory.DeviceCleanupWorker.enqueue_manual(actor) do
          {:ok, _job} -> {:ok, %{scheduled: true}}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_operator_plus()
    operator_action([:create, :update, :run_cleanup])
  end

  attributes do
    attribute :key, :string do
      allow_nil? false
      default "default"
      primary_key? true
      public? false
    end

    attribute :retention_days, :integer do
      allow_nil? false
      default 30
      public? true
      constraints min: 1, max: 3650
      description "Number of days to keep soft-deleted devices before purging"
    end

    attribute :cleanup_interval_minutes, :integer do
      allow_nil? false
      default 1_440
      public? true
      constraints min: 5, max: 43_200
      description "How often to run device cleanup (minutes)"
    end

    attribute :batch_size, :integer do
      allow_nil? false
      default 1_000
      public? true
      constraints min: 100, max: 50_000
      description "Batch size for device cleanup deletes"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether device cleanup scheduling is enabled"
    end

    attribute :ephemeral_expiry_enabled, :boolean do
      allow_nil? false
      default false
      public? true

      description "Whether devices with no strong identifier are soft-deleted once unseen " <>
                    "for ephemeral_expiry_days (off by default)"
    end

    attribute :ephemeral_expiry_days, :integer do
      allow_nil? false
      default 30
      public? true
      constraints min: 1, max: 3650
      description "Days a device with no strong identifier may go unseen before it expires"
    end

    attribute :ephemeral_expiry_exclusion_query, :string do
      allow_nil? true
      public? true
      description "SRQL device query whose matching devices are never expired"
    end

    attribute :ephemeral_expiry_max_fraction, :float do
      allow_nil? false
      default 0.5
      public? true
      constraints min: 0.01, max: 1.0

      description "Largest fraction of live devices one expiry pass may expire; a larger " <>
                    "pass is refused"
    end

    attribute :ephemeral_expiry_guard_override, :boolean do
      allow_nil? false
      default false
      public? true

      description "Let one expiry pass exceed ephemeral_expiry_max_fraction (a deliberate " <>
                    "first cleanup); leave off in steady state"
    end

    attribute :source_retirement_enabled, :boolean do
      allow_nil? false
      default true
      public? true

      description "Whether a source id its source stopped reporting is retired after " <>
                    "sustained absence from exact collections"
    end

    attribute :source_retirement_absent_collections, :integer do
      allow_nil? false
      default 3
      public? true
      constraints min: 2, max: 32

      description "Consecutive exact collections, under one collection query, a source id " <>
                    "must be absent from before it retires"
    end

    attribute :source_retirement_min_absence_hours, :integer do
      allow_nil? false
      default 24
      public? true
      constraints min: 1, max: 8_760
      description "Hours since a source id was last reported before it may retire"
    end

    attribute :source_retirement_max_fraction, :float do
      allow_nil? false
      default 0.5
      public? true
      constraints min: 0.01, max: 1.0

      description "Largest fraction of a source instance's live records one retirement pass " <>
                    "may affect, and of all live records one grace pass may delete; a larger " <>
                    "pass is refused"
    end

    attribute :source_retirement_guard_override, :boolean do
      allow_nil? false
      default false
      public? true

      description "Let the next retirement or grace pass exceed " <>
                    "source_retirement_max_fraction; the pass it admits clears it"
    end

    attribute :source_retired_grace_days, :integer do
      allow_nil? false
      default 7
      public? true
      constraints min: 1, max: 365

      description "Days a record left holding only retired source ids stays hidden before it " <>
                    "is soft-deleted"
    end

    attribute :max_successions_per_run, :integer do
      allow_nil? false
      default 200
      public? true
      constraints min: 0, max: 10_000
      description "Most source succession merges one reconciliation run may perform"
    end

    timestamps()
  end
end
