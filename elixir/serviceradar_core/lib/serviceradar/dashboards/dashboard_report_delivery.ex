defmodule ServiceRadar.Dashboards.DashboardReportDelivery do
  @moduledoc """
  Delivery attempt for an authored dashboard report schedule.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "analytics.view"}
  @view_all_check {ActorHasPermission, permission: "analytics.dashboards.view_all"}
  @fields [
    :schedule_id,
    :dashboard_id,
    :due_at,
    :status,
    :recipients,
    :recipient_count,
    :message_id,
    :error,
    :rendered_metadata
  ]

  postgres do
    table "dashboard_report_deliveries"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    references do
      reference :schedule, on_delete: :delete
      reference :dashboard, on_delete: :nilify
    end
  end

  code_interface do
    define :list, action: :read
    define :list_for_dashboard, action: :for_dashboard, args: [:dashboard_id]
    define :list_for_schedule, action: :for_schedule, args: [:schedule_id]
    define :get_by_id, action: :by_id, args: [:id]
    define :create_delivery, action: :create
    define :mark_running, action: :mark_running
    define :mark_sent, action: :mark_sent
    define :mark_failed, action: :mark_failed
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_dashboard do
      argument :dashboard_id, :uuid, allow_nil?: false
      filter expr(dashboard_id == ^arg(:dashboard_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_schedule do
      argument :schedule_id, :uuid, allow_nil?: false
      filter expr(schedule_id == ^arg(:schedule_id))
      prepare build(sort: [inserted_at: :desc])
    end

    create :create do
      accept @fields
      upsert? true
      upsert_identity :unique_schedule_due

      upsert_fields [:updated_at]
    end

    update :mark_running do
      accept []
      change set_attribute(:status, :running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change set_attribute(:error, nil)
    end

    update :mark_sent do
      accept [:message_id, :rendered_metadata]
      change set_attribute(:status, :sent)
      change set_attribute(:sent_at, &DateTime.utc_now/0)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change set_attribute(:error, nil)
    end

    update :mark_failed do
      accept [:error, :rendered_metadata]
      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      forbid_unless @view_check
      authorize_if @view_all_check
      authorize_if ServiceRadar.Dashboards.Checks.ActorCanAccessDashboardChild
    end

    # Delivery rows and state transitions are internal scanner/worker state.
    # The system_bypass above authorizes those paths; users can only read them.
  end

  attributes do
    uuid_primary_key :id

    attribute :schedule_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :dashboard_id, :uuid do
      public? true
    end

    attribute :due_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :running, :sent, :failed]
    end

    attribute :recipients, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :recipient_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :message_id, :string do
      public? true
    end

    attribute :error, :string do
      public? true
    end

    attribute :rendered_metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :started_at, :utc_datetime_usec do
      public? true
    end

    attribute :finished_at, :utc_datetime_usec do
      public? true
    end

    attribute :sent_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :schedule, ServiceRadar.Dashboards.DashboardReportSchedule do
      allow_nil? false
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :schedule_id
    end

    belongs_to :dashboard, ServiceRadar.Dashboards.AuthoredDashboard do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :dashboard_id
    end
  end

  identities do
    identity :unique_schedule_due, [:schedule_id, :due_at]
  end
end
