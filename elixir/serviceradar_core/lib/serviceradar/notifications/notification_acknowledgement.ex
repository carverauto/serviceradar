defmodule ServiceRadar.Notifications.NotificationAcknowledgement do
  @moduledoc """
  Audit of an inbound action taken against an alert from a notification (design D7).

  Every acknowledge, snooze, resolve, suppress, and unacknowledge that arrives
  from outside the alert detail page lands here: signed action links in Phase 1,
  native interactive components (Slack Block Kit, Discord message components,
  PagerDuty acknowledgement webhooks) in Phase 4.

  This resource is deliberately **not** paper-trailed. There is no
  `notification_acknowledgements_versions` table because the row is already an
  append-only audit record of a single inbound event; it is never edited, so a
  version table would record nothing.

  ## Actor identity is explicit, not inferred

  `alerts.acknowledged_by` and `resolved_by` are free-text strings with no
  foreign key, which makes "who acknowledged this?" unanswerable. `actor_kind`
  records the distinction outright:

  - `:platform_user` - a real `ServiceRadar.Identity.User`; `actor_user_id` is
    required.
  - `:external_principal` - an identity outside the platform; `external_principal`
    is required.
  - `:system` - the platform acted on its own behalf (auto-resolve, snooze
    expiry); neither field is required.

  Those requirements mirror the `notification_acknowledgements_actor` database
  check exactly.

  ## `external_principal` is an opaque string on purpose (OPEN QUESTION)

  Mapping an external chat identity - a Slack user - onto a platform user is an
  **open question deferred to Phase 4**. A Slack interaction payload is
  authenticated to the *workspace* by the signing secret, not to an individual,
  so an unbound mapping would let any workspace member forge another member's
  acknowledgement. The candidate designs are an explicit external-identity
  mapping resource, verified-email matching, or refusing to map at all and
  requiring a signed action link that carries a platform session.

  Until that is resolved, `external_principal` stays an opaque string and is
  never silently promoted to an `actor_user_id`. Phase 1 is unaffected: its
  signed action links carry their own authorisation.

  ## Snooze

  A `:snooze` action requires `snooze_until`, mirroring the
  `notification_acknowledgements_snooze` database check. It is `snooze_until`
  everywhere - this record, the alert attribute, and the UI. Snooze is
  deliberately not an alert state-machine state; "snoozed" is derived from
  `status in [:pending, :escalated] and snooze_until > now()`.

  Per design D4, the one exception to measuring escalation delays from alert fire
  time is a snooze: after a snooze expires the remaining step delays are measured
  from the snooze expiry instant, because snoozing is an explicit operator
  statement that the clock should restart.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "notifications.deliveries.view"}

  # The EXISTING alert permission, described verbatim in the RBAC catalog as
  # "Acknowledge and resolve alerts". Notifications do not mint a second key for
  # the same authority.
  @acknowledge_check {ActorHasPermission, permission: "observability.alerts.manage"}

  @fields [
    :delivery_id,
    :alert_id,
    :action,
    :actor_kind,
    :actor_user_id,
    :external_principal,
    :note,
    :snooze_until,
    :source,
    :received_at
  ]

  postgres do
    table "notification_acknowledgements"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :delivery, on_delete: :nilify
      reference :alert, on_delete: :nilify
      reference :actor_user, on_delete: :nilify
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_alert, action: :for_alert, args: [:alert_id]
    define :list_for_delivery, action: :for_delivery, args: [:delivery_id]
    define :record_action, action: :record
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

    read :for_alert do
      argument :alert_id, :uuid, allow_nil?: false

      filter expr(alert_id == ^arg(:alert_id))
      prepare build(sort: [received_at: :desc])
    end

    read :for_delivery do
      argument :delivery_id, :uuid, allow_nil?: false

      filter expr(delivery_id == ^arg(:delivery_id))
      prepare build(sort: [received_at: :desc])
    end

    create :record do
      description """
      Record one inbound action. Append-only: an acknowledgement is never edited,
      which is why this resource has no update action.
      """

      primary? true
      accept @fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission([:read, :by_id, :for_alert, :for_delivery], @view_check)

    # Acknowledgement ingress is authenticated: an operator acting through the
    # UI or API, or the platform itself (system actor, bypassed above) relaying a
    # verified signed action link or provider callback. There is deliberately no
    # actor-is-nil allowance here - an unauthenticated write to this table would
    # be a forged acknowledgement.
    policy action_type(:create) do
      authorize_if @acknowledge_check
    end

    # No policy authorizes destroy, so only the system-actor bypass above can
    # prune. An inbound-action audit row is not operator-destroyable.
  end

  validations do
    # Mirrors notification_acknowledgements_actor. `:system` requires neither
    # field, which is why this is two scoped validations rather than one.
    validate present(:actor_user_id) do
      where attribute_equals(:actor_kind, :platform_user)
      message "a platform_user acknowledgement must name the user"
    end

    validate present(:external_principal) do
      where attribute_equals(:actor_kind, :external_principal)
      message "an external_principal acknowledgement must name the principal"
    end

    # Mirrors notification_acknowledgements_snooze.
    validate present(:snooze_until) do
      where attribute_equals(:action, :snooze)
      message "a snooze must say what it is snoozed until"
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :delivery_id, :uuid do
      allow_nil? true
      public? true
      description "The delivery whose action link or callback carried this action, when known."
    end

    attribute :alert_id, :uuid do
      allow_nil? true
      public? true
      description "Nullable: the FK is nilify_all and alerts are pruned after 3 days."
    end

    attribute :action, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:acknowledge, :snooze, :resolve, :suppress, :unacknowledge]
    end

    attribute :actor_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:platform_user, :external_principal, :system]
    end

    attribute :actor_user_id, :uuid do
      allow_nil? true
      public? true
      description "Required when actor_kind is :platform_user."
    end

    attribute :external_principal, :string do
      allow_nil? true
      public? true

      description """
      Opaque external identity, required when actor_kind is :external_principal.
      Mapping a chat identity onto a platform user is an OPEN QUESTION deferred
      to Phase 4; this is never silently promoted to actor_user_id.
      """
    end

    attribute :note, :string, allow_nil?: true, public?: true

    attribute :snooze_until, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Required when action is :snooze. Named snooze_until everywhere."
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ui, :api, :callback, :action_link]
      description "How the action arrived. :action_link is the Phase 1 signed capability link."
    end

    attribute :received_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
      description "When the platform received the action, which may precede inserted_at."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :delivery, ServiceRadar.Notifications.NotificationDelivery do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :delivery_id
    end

    belongs_to :alert, ServiceRadar.Monitoring.Alert do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :alert_id
    end

    belongs_to :actor_user, ServiceRadar.Identity.User do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :actor_user_id
    end
  end
end
