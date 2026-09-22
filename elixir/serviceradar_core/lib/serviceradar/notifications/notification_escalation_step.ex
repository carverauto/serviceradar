defmodule ServiceRadar.Notifications.NotificationEscalationStep do
  @moduledoc """
  One rung of a `NotificationEscalationPolicy` ladder (design D4, C6).

  A step is *when* a policy tries again and *under what human condition*. The
  set of channels a step fans out to lives on
  `ServiceRadar.Notifications.NotificationEscalationStepChannel`, because
  fan-out is orthogonal to escalation: one step notifies many channels at once,
  the next step is a later attempt at a human who has still not answered.

      Step 1  t+0     -> [Slack #noc, Email noc@]           fan-out
      Step 2  t+5m    -> [PagerDuty]            if unacked  escalation
      Step 3  t+15m   -> [PagerDuty P1, SMS]    if unacked

  ## delay_seconds is measured from the ALERT FIRE TIME

  This is the single most commonly mis-implemented rule in this resource, so it
  is stated three times: in this moduledoc, on the attribute description, and in
  design D4.

  `delay_seconds` is an offset from the instant the alert fired. It is **never**
  an offset from the previous step's dispatch, and never an offset from the
  previous step's delivery result. Chaining delays off the previous dispatch
  makes total time-to-page depend on transport latency and retry behaviour, so
  an escalation policy stops meaning what its author read: a "5m / 15m" ladder
  silently becomes "5m / 15m plus however long two retries took". Because
  `delay_seconds` is absolute, the numbers on a ladder are always the wall-clock
  offsets an operator can reason about, and steps are strictly ordered by
  `step_number` with strictly non-decreasing delays.

  There is exactly **one** exception, and this resource does not enforce it:
  after a snooze expires, the remaining step delays are measured from the
  **snooze expiry instant**, because snoozing is an explicit operator statement
  that the clock should restart. That rebasing belongs to the dispatch
  scheduler, which is the only component that knows about
  `snooze_until`; nothing about a step row changes when it happens.

  ## Ordering and uniqueness

  `step_number` starts at 1 and is unique per policy
  (`notification_escalation_steps_policy_step_uidx`). Deleting a policy deletes
  its steps.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "notifications.routes.view"}
  @manage_check {ActorHasPermission, permission: "notifications.routes.manage"}

  @fields [
    :policy_id,
    :step_number,
    :delay_seconds,
    :condition
  ]

  postgres do
    table "notification_escalation_steps"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names policy_step: "notification_escalation_steps_policy_step_uidx"

    references do
      reference :policy, on_delete: :delete
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "notification_escalation_step_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  json_api do
    type "notification_escalation_step"

    routes do
      base "/notification-escalation-steps"

      index :read
      post :create
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_policy_step, action: :by_policy_step, args: [:policy_id, :step_number]
    define :list_for_policy, action: :for_policy, args: [:policy_id]
    define :create_step, action: :create
    define :update_step, action: :update
    define :destroy_step, action: :destroy
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

    read :by_policy_step do
      argument :policy_id, :uuid, allow_nil?: false
      argument :step_number, :integer, allow_nil?: false

      get? true
      filter expr(policy_id == ^arg(:policy_id) and step_number == ^arg(:step_number))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    # The ladder in author order. Escalation evaluation walks this ascending.
    read :for_policy do
      argument :policy_id, :uuid, allow_nil?: false

      filter expr(policy_id == ^arg(:policy_id))
      prepare build(sort: [step_number: :asc], select: [:id, :inserted_at, :updated_at | @fields])
    end

    create :create do
      accept @fields
    end

    update :update do
      accept [:step_number, :delay_seconds, :condition]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_policy_step, :for_policy], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :policy_id, :uuid, allow_nil?: false, public?: true

    attribute :step_number, :integer do
      allow_nil? false
      public? true
      # Mirrors the CHECK in notification_escalation_steps_bounds.
      constraints min: 1
      description "1-based position in the ladder, unique per escalation policy"
    end

    attribute :delay_seconds, :integer do
      allow_nil? false
      public? true
      default 0
      # Mirrors the CHECK in notification_escalation_steps_bounds.
      constraints min: 0

      description """
      Offset from the ALERT FIRE TIME at which this step fires, never an offset \
      from the previous step's dispatch. The one exception, applied by the \
      dispatch scheduler rather than by this resource, is that after a snooze \
      expires the remaining delays are measured from the snooze expiry instant.\
      """
    end

    attribute :condition, :atom do
      allow_nil? false
      public? true
      default :if_unacknowledged
      constraints one_of: [:always, :if_unacknowledged]

      description """
      :if_unacknowledged fires the step only while the alert is still \
      unacknowledged; :always fires it regardless, for ladders that must reach \
      a downstream system even after a human has taken the page.\
      """
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :policy, ServiceRadar.Notifications.NotificationEscalationPolicy do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :policy_id
    end

    has_many :step_channels, NotificationEscalationStepChannel do
      destination_attribute :step_id
      public? true
    end

    many_to_many :channels, ServiceRadar.Notifications.NotificationChannel do
      through NotificationEscalationStepChannel
      source_attribute_on_join_resource :step_id
      destination_attribute_on_join_resource :channel_id
      public? true
    end
  end

  identities do
    identity :policy_step, [:policy_id, :step_number]
  end
end
