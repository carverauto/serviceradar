defmodule ServiceRadar.Observability.WarehouseRetentionSetting do
  @moduledoc """
  The operator's retention for one StarRocks warehouse dataset (one row per dataset).

  `days` is the effective setting. Core seeds a missing row from the environment
  (`SERVICERADAR_STARROCKS_RETENTION_DAYS_<DATASET>`, Helm
  `analytics.starrocks.retentionDays`, Compose) and records that seed in `seed_days`
  on every start, but never overwrites `days` with it: once a row exists the stored
  value wins. `ServiceRadar.Analytics.StarRocks.Retention` applies `days` to the
  dataset's tables and records the outcome in the `last_applied_*` columns, so the
  Data retention settings page shows whether the warehouse took the value.

  `updated_by`/`updated_at` describe the last operator change, not the applier's
  bookkeeping writes, which is why there is no `update_timestamp`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.Observability.WarehouseRetentionNotifier]

  alias ServiceRadar.Observability.Changes.StampRetentionChange
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "settings.data_retention.view"}
  @manage_check {ActorHasPermission, permission: "settings.data_retention.manage"}

  @max_days 3650

  @type t :: %__MODULE__{}

  postgres do
    table "warehouse_retention_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    check_constraints do
      check_constraint :days, "warehouse_retention_settings_days_floor",
        check: "days BETWEEN 1 AND #{@max_days}",
        message: "must be between 1 and #{@max_days} days"
    end
  end

  code_interface do
    define :list, action: :read
    define :seed, action: :seed
    define :create_setting, action: :create
    define :set_days, action: :set_days
    define :record_seed, action: :record_seed
    define :record_outcome, action: :record_outcome
  end

  actions do
    defaults [:read]

    # Core only: a dataset first seen at boot takes its environment seed.
    create :seed do
      accept [:dataset, :days, :seed_days]
    end

    # An operator saving a dataset core has not seeded yet (warehouse disabled,
    # or core not started since the dataset was added).
    create :create do
      accept [:dataset, :days]
      change StampRetentionChange
    end

    update :set_days do
      accept [:days]
      change StampRetentionChange
    end

    # Core only: the environment seed this core started with.
    update :record_seed do
      accept [:seed_days]
    end

    # Core only: what the warehouse did with `days`.
    update :record_outcome do
      accept [:last_applied_days, :last_applied_status, :last_applied_error, :last_applied_at]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
    end

    policy action([:create, :set_days]) do
      authorize_if @manage_check
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :dataset, :string do
      allow_nil? false
      public? true
    end

    attribute :days, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: @max_days
    end

    attribute :seed_days, :integer do
      public? true
      constraints min: 1
    end

    attribute :updated_by, :string do
      public? true
    end

    attribute :updated_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_applied_days, :integer do
      public? true
    end

    # applied | pending | failed (the table's check constraint).
    attribute :last_applied_status, :string do
      allow_nil? false
      default "pending"
      public? true
    end

    attribute :last_applied_error, :string do
      public? true
      constraints allow_empty?: true
    end

    attribute :last_applied_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_dataset, [:dataset]
  end

  @doc "The largest retention a dataset accepts."
  @spec max_days() :: pos_integer()
  def max_days, do: @max_days
end
