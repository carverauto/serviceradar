defmodule ServiceRadar.Dashboards.DashboardReportSchedule do
  @moduledoc """
  Email report schedule for an authored dashboard.

  A periodic scanner finds due schedules and enqueues individual delivery jobs;
  this resource intentionally represents data, not one runtime scheduler per
  report.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Dashboards.Checks.ActorCanEditDashboardTarget
  alias ServiceRadar.Dashboards.Validations.ReportScheduleFields
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "analytics.view"}
  @view_all_check {ActorHasPermission, permission: "analytics.dashboards.view_all"}
  @schedule_check {ActorHasPermission, permission: "analytics.reports.schedule"}

  @fields [
    :dashboard_id,
    :name,
    :enabled,
    :recipients,
    :cron,
    :timezone,
    :format,
    :next_due_at,
    :metadata
  ]

  postgres do
    table "dashboard_report_schedules"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    references do
      reference :dashboard, on_delete: :delete
    end
  end

  paper_trail do
    primary_key_type :uuid
    table_name "dashboard_report_schedule_versions"
    mixin {ServiceRadar.Dashboards.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at, :last_due_at, :last_delivered_at, :next_due_at]
  end

  code_interface do
    define :list, action: :read
    define :list_due, action: :due
    define :list_for_dashboard, action: :for_dashboard, args: [:dashboard_id]
    define :get_by_id, action: :by_id, args: [:id]
    define :create_schedule, action: :create
    define :update_schedule, action: :update
    define :enable, action: :enable
    define :disable, action: :disable
    define :record_due_enqueue, action: :record_due_enqueue
    define :record_delivery, action: :record_delivery
    define :record_failure, action: :record_failure
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
      prepare build(sort: [name: :asc])
    end

    read :due do
      filter expr(enabled == true and not is_nil(next_due_at) and next_due_at <= now())
    end

    create :create do
      accept @fields
      validate ReportScheduleFields
    end

    update :update do
      accept @fields -- [:dashboard_id]
      validate ReportScheduleFields
    end

    update :enable do
      accept [:next_due_at]
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []
      change set_attribute(:enabled, false)
    end

    update :record_due_enqueue do
      accept [:next_due_at]

      argument :due_at, :utc_datetime_usec do
        allow_nil? false
      end

      change set_attribute(:last_due_at, arg(:due_at))
      change set_attribute(:last_status, :queued)
      change set_attribute(:last_error, nil)
      validate ServiceRadar.Dashboards.Validations.NextDueAdvances
    end

    update :record_delivery do
      accept []
      change set_attribute(:last_delivered_at, &DateTime.utc_now/0)
      change set_attribute(:last_status, :sent)
      change set_attribute(:last_error, nil)
    end

    update :record_failure do
      accept [:last_error]
      change set_attribute(:last_status, :failed)
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

    policy action([:create, :update, :enable, :disable, :destroy]) do
      forbid_unless @schedule_check
      authorize_if ActorCanEditDashboardTarget
      authorize_if ServiceRadar.Dashboards.Checks.ActorCanSchedulePublicDashboard
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :dashboard_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :recipients, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :cron, :string do
      allow_nil? false
      public? true
      description "Standard 5-field cron expression."
    end

    attribute :timezone, :string do
      allow_nil? false
      public? true
      default "UTC"
    end

    attribute :format, :atom do
      allow_nil? false
      public? true
      default :html
      constraints one_of: [:html]
    end

    attribute :next_due_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_due_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_delivered_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_status, :atom do
      public? true
      constraints one_of: [:queued, :sent, :failed]
    end

    attribute :last_error, :string do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :dashboard, ServiceRadar.Dashboards.AuthoredDashboard do
      allow_nil? false
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :dashboard_id
    end

    has_many :deliveries, ServiceRadar.Dashboards.DashboardReportDelivery do
      destination_attribute :schedule_id
    end
  end
end
