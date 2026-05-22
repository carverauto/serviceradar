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
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "analytics.view"}
  @manage_check {ActorHasPermission, permission: "analytics.manage_queries"}

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
    table("dashboard_report_schedules")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)

    references do
      reference(:dashboard, on_delete: :delete)
    end
  end

  code_interface do
    define(:list, action: :read)
    define(:list_due, action: :due)
    define(:list_for_dashboard, action: :for_dashboard, args: [:dashboard_id])
    define(:get_by_id, action: :by_id, args: [:id])
    define(:create_schedule, action: :create)
    define(:update_schedule, action: :update)
    define(:enable, action: :enable)
    define(:disable, action: :disable)
    define(:record_due_enqueue, action: :record_due_enqueue)
    define(:record_delivery, action: :record_delivery)
    define(:record_failure, action: :record_failure)
  end

  actions do
    defaults([:read, :destroy])

    read :by_id do
      argument(:id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    read :for_dashboard do
      argument(:dashboard_id, :uuid, allow_nil?: false)
      filter(expr(dashboard_id == ^arg(:dashboard_id)))
      prepare(build(sort: [name: :asc]))
    end

    read :due do
      filter(expr(enabled == true and not is_nil(next_due_at) and next_due_at <= now()))
    end

    create :create do
      accept(@fields)
    end

    update :update do
      accept(@fields -- [:dashboard_id])
    end

    update :enable do
      accept([:next_due_at])
      change(set_attribute(:enabled, true))
    end

    update :disable do
      accept([])
      change(set_attribute(:enabled, false))
    end

    update :record_due_enqueue do
      accept([:next_due_at])

      argument :due_at, :utc_datetime_usec do
        allow_nil?(false)
      end

      change(set_attribute(:last_due_at, arg(:due_at)))
      change(set_attribute(:last_status, :queued))
      change(set_attribute(:last_error, nil))
    end

    update :record_delivery do
      accept([])
      change(set_attribute(:last_delivered_at, &DateTime.utc_now/0))
      change(set_attribute(:last_status, :sent))
      change(set_attribute(:last_error, nil))
    end

    update :record_failure do
      accept([:last_error])
      change(set_attribute(:last_status, :failed))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :dashboard_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
    end

    attribute :recipients, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
    end

    attribute :cron, :string do
      allow_nil?(false)
      public?(true)
      description("Standard 5-field cron expression.")
    end

    attribute :timezone, :string do
      allow_nil?(false)
      public?(true)
      default("UTC")
    end

    attribute :format, :atom do
      allow_nil?(false)
      public?(true)
      default(:html)
      constraints(one_of: [:html])
    end

    attribute :next_due_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :last_due_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :last_delivered_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :last_status, :atom do
      public?(true)
      constraints(one_of: [:queued, :sent, :failed])
    end

    attribute :last_error, :string do
      public?(true)
    end

    attribute :metadata, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :dashboard, ServiceRadar.Dashboards.AuthoredDashboard do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
      define_attribute?(false)
      source_attribute(:dashboard_id)
    end

    has_many :deliveries, ServiceRadar.Dashboards.DashboardReportDelivery do
      destination_attribute(:schedule_id)
    end
  end
end
