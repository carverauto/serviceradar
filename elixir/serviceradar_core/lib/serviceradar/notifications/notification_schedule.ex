defmodule ServiceRadar.Notifications.NotificationSchedule do
  @moduledoc """
  A simple recurring time window that gates a `NotificationRoute`.

  When a route references a schedule and the dispatch instant falls outside the
  schedule's effective active period, the dispatch is suppressed with
  `suppression_reason: :schedule` and still leaves a `NotificationDelivery` row,
  because suppression is enumerable and auditable (design D5).

  ## Explicitly NOT rotations

  On-call rotation calendars, shift handoffs, and override management are a
  stated Non-Goal of the notification platform. ServiceRadar integrates with
  PagerDuty and Opsgenie for those rather than reimplementing them. This
  resource ships only "business hours" / "after hours" style recurring windows;
  do not grow it into a rotation engine.

  ## Window shape

  `windows` is a list of `{days, start_time, end_time}` entries stored as JSON
  maps. Each entry has:

  - `"days"` - a non-empty list of day-of-week tokens drawn from
    `mon tue wed thu fri sat sun`.
  - `"start_time"` / `"end_time"` - wall-clock times as `"HH:MM"` or
    `"HH:MM:SS"`, with `end_time` strictly after `start_time`.

  A window that wraps past midnight is NOT expressible as a single entry, by
  design: `end_time > start_time` is what keeps window evaluation a plain
  comparison. Express "overnight" either as `mode: :active_outside` of the
  daytime window, or as two entries on the adjacent days.

  `mode` inverts the window set: `:active_within` is active inside the windows,
  `:active_outside` is active everywhere else.

  Window evaluation is performed in `timezone`, including across daylight-saving
  transitions. The evaluator resolves wall time through PostgreSQL's installed
  IANA database, and save-time validation rejects names that database does not
  know. This keeps the accepted configuration and the dispatch-time resolver on
  one source of truth without adding a second time-zone data dependency.

  See `openspec/changes/add-notification-platform/design.md` (Data Model,
  `NotificationSchedule`) and the "Notification schedules" requirement in
  `specs/notification-platform/spec.md`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.Validations.ScheduleWindows
  alias ServiceRadar.Notifications.Validations.SupportedScheduleTimezone
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "notifications.routes.view"}
  @manage_check {ActorHasPermission, permission: "notifications.routes.manage"}

  @modes [:active_within, :active_outside]

  @fields [
    :name,
    :description,
    :timezone,
    :windows,
    :mode,
    :enabled
  ]

  @doc "Schedule modes. `:active_within` is inside the windows, `:active_outside` inverts them."
  def modes, do: @modes

  postgres do
    table "notification_schedules"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_name: "notification_schedules_name_uidx"
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "notification_schedule_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_name, action: :by_name, args: [:name]
    define :list_enabled, action: :enabled
    define :create_schedule, action: :create
    define :update_schedule, action: :update
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :by_name do
      argument :name, :string, allow_nil?: false
      get? true
      filter expr(name == ^arg(:name))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :enabled do
      filter expr(enabled == true)
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    create :create do
      accept @fields
    end

    update :update do
      accept @fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    read_with_permission(@view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  validations do
    validate {ScheduleWindows, []}
    validate {SupportedScheduleTimezone, []}
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :timezone, :string do
      allow_nil? false
      public? true
      default "Etc/UTC"
      description "IANA zone name that window boundaries are evaluated in"
    end

    attribute :windows, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description """
      List of {days, start_time, end_time} entries. days is a non-empty list of \
      mon/tue/wed/thu/fri/sat/sun; times are HH:MM or HH:MM:SS wall clock with \
      end_time strictly after start_time.\
      """
    end

    attribute :mode, :atom do
      allow_nil? false
      public? true
      default :active_within
      constraints one_of: @modes
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :routes, ServiceRadar.Notifications.NotificationRoute do
      destination_attribute :schedule_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
