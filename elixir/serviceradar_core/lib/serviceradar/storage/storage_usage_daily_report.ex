defmodule ServiceRadar.Storage.StorageUsageDailyReport do
  @moduledoc """
  Persisted closed-UTC-day storage usage report (`platform.storage_usage_daily_reports`,
  `F.6`, `design.md` `F5`, `spec.md:742-759`).

  Each closed UTC day (`usage_date < Date.utc_today()`) is computed once at
  `report_revision = 1` so repeated reads of the same closed day return the
  exact same `report_revision` and figures (`spec.md:756-759`). A correction
  revises the row only via explicit recomputation incrementing `report_revision`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}

  postgres do
    table "storage_usage_daily_reports"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names unique_usage_date: "storage_usage_daily_reports_usage_date_index"

    check_constraints do
      check_constraint :report_revision, "storage_usage_daily_reports_revision_positive",
        check: "report_revision >= 1"
    end
  end

  code_interface do
    define :get_by_date, action: :by_date, args: [:usage_date]
    define :list_in_range, action: :in_range, args: [:from_date, :to_date]
  end

  actions do
    defaults [:read]

    read :by_date do
      argument :usage_date, :date, allow_nil?: false
      get? true
      filter expr(usage_date == ^arg(:usage_date))
    end

    read :in_range do
      argument :from_date, :date, allow_nil?: false
      argument :to_date, :date, allow_nil?: false
      filter expr(usage_date >= ^arg(:from_date) and usage_date <= ^arg(:to_date))
      prepare build(sort: [usage_date: :asc])
    end

    create :record_initial do
      primary? true
      accept [:usage_date, :payload, :computed_at]
      upsert? true
      upsert_identity :unique_usage_date
      upsert_fields []
      change set_attribute(:report_revision, 1)
    end

    update :revise_report do
      primary? true
      accept [:payload, :computed_at]
      atomic_upgrade_with :read
      change atomic_update(:report_revision, expr(report_revision + 1))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
    end

    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :usage_date, :date do
      allow_nil? false
      public? true
    end

    attribute :report_revision, :integer do
      allow_nil? false
      default 1
      writable? false
      public? true
      constraints min: 1
    end

    attribute :payload, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :computed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  identities do
    identity :unique_usage_date, [:usage_date]
  end
end
