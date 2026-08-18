defmodule ServiceRadar.Notifications.NotificationSilence do
  @moduledoc """
  An operator-declared maintenance window that mutes matching notifications.

  Implements design D5 ("Suppression is enumerable, auditable, and re-evaluated
  at dispatch") and the "Silences and maintenance windows" requirement. A silence
  is a *suppression source*, not a delete: when a dispatch is withheld because a
  silence matched, the dispatcher still commits a `NotificationDelivery` row with
  `state: :suppressed` and `suppression_reason: :silence`. Silencing something
  never makes it invisible; it moves it to the Delivery Log, which is the surface
  that answers "why was I not paged?".

  ## Why `comment` is required

  The column is `NOT NULL` in the migration and the attribute is `allow_nil?
  false` here, deliberately. A silence is the one object in this domain whose
  entire purpose is to stop a page, and an unexplained silence found weeks later
  is indistinguishable from a bug. An operator states why. Note that Ash casts an
  all-whitespace `:string` to `nil` before the nil check, so `""` and `"   "` are
  rejected as missing rather than accepted as an explanation.

  ## `matchers` share the route grammar

  `matchers` uses `ServiceRadar.Notifications.MatchExpression` - the same
  declarative predicate grammar as `NotificationRoute.match_expression`. One
  grammar, one validator; see that module for the reasoning and the shape. The
  document is never executed, only matched, in line with design D9.

  ## State machine and the sweeper

  `state` moves `:scheduled -> :active -> :expired`, with `:cancelled` reachable
  from either live state. An Oban sweeper owns the clock transitions and drives
  them through `:activate` and `:expire`; it selects work with `:due_to_activate`
  and `:due_to_expire`, whose filters already exclude rows in the target state,
  so a re-run of the same sweeper tick is a no-op and the job stays idempotent as
  the Iron Laws require.

  Suppression evaluation reads `:active_at`, which requires `state == :active`
  **and** the instant to fall inside the window. Both halves matter: the state is
  what the requirement makes normative (a `:cancelled` silence stops suppressing
  immediately, without waiting for `ends_at`), and the window bound is what keeps
  a lagging sweeper from extending a silence past the time an operator asked for.

  ## Attribution

  `created_by_user_id` is a real foreign key to `ServiceRadar.Identity.User`;
  `created_by` remains free text for an external principal, mirroring the actor
  split design D7 introduces for acknowledgements. Both are supplied by the
  calling layer rather than inferred from the actor here, because a silence can
  legitimately be created by a service principal that is not a platform user.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.MatchExpression
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  # Silences are read alongside routes, policies, and schedules on the routing
  # surface, so they share the routing view permission. Writing one stops pages
  # and therefore needs its own key.
  @view_check {ActorHasPermission, permission: "notifications.routes.view"}
  @manage_check {ActorHasPermission, permission: "notifications.silences.manage"}

  @fields [
    :name,
    :matchers,
    :starts_at,
    :ends_at,
    :created_by_user_id,
    :created_by,
    :comment,
    :state
  ]

  @writable_fields [
    :name,
    :matchers,
    :starts_at,
    :ends_at,
    :created_by_user_id,
    :created_by,
    :comment
  ]

  postgres do
    table "notification_silences"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :created_by_user, on_delete: :nilify
    end
  end

  state_machine do
    initial_states [:scheduled]
    default_initial_state :scheduled
    state_attribute :state

    transitions do
      transition :activate, from: [:scheduled], to: :active
      transition :expire, from: [:scheduled, :active], to: :expired
      transition :cancel, from: [:scheduled, :active], to: :cancelled
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "notification_silence_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active_at, action: :active_at, args: [:at]
    define :list_due_to_activate, action: :due_to_activate, args: [:at]
    define :list_due_to_expire, action: :due_to_expire, args: [:at]
    define :create_silence, action: :create
    define :update_silence, action: :update
    define :activate, action: :activate
    define :expire, action: :expire
    define :cancel, action: :cancel
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

    # Suppression evaluator entry point. A silence suppresses only while it is
    # :active AND the evaluation instant is inside its window; see the moduledoc
    # for why both halves are checked.
    read :active_at do
      argument :at, :utc_datetime_usec, allow_nil?: false

      filter expr(
               state == :active and starts_at <= ^arg(:at) and
                 ends_at > ^arg(:at)
             )

      prepare build(
                select: [:id, :inserted_at, :updated_at | @fields],
                sort: [starts_at: :asc, id: :asc]
              )
    end

    # Sweeper selection. Filtering on the source state is what makes a repeated
    # sweeper tick a no-op instead of a state-machine error.
    read :due_to_activate do
      argument :at, :utc_datetime_usec, allow_nil?: false

      filter expr(state == :scheduled and starts_at <= ^arg(:at) and ends_at > ^arg(:at))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields], sort: [starts_at: :asc])
    end

    read :due_to_expire do
      argument :at, :utc_datetime_usec, allow_nil?: false

      filter expr(state in [:scheduled, :active] and ends_at <= ^arg(:at))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields], sort: [ends_at: :asc])
    end

    create :create do
      accept @writable_fields
    end

    update :update do
      accept @writable_fields
    end

    update :activate do
      change transition_state(:active)
    end

    update :expire do
      change transition_state(:expired)
    end

    update :cancel do
      change transition_state(:cancelled)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :active_at], @view_check)
    action_with_permission([:due_to_activate, :due_to_expire], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:activate, :expire, :cancel], @manage_check)
  end

  validations do
    # Mirrors the notification_silences_window CHECK constraint so the operator
    # gets a field error instead of a database exception. The bare atom is the
    # attribute-reference form Compare implements in both its changeset and its
    # atomic path; the `{:ref, :starts_at}` tagged tuple the option schema also
    # accepts is not resolved by either and silently compares against the tuple.
    validate compare(:ends_at, greater_than: :starts_at),
      message: "must be after starts_at"

    validate {MatchExpression, attribute: :matchers}
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? true
      public? true
      description "Optional operator label for the maintenance window"
    end

    attribute :matchers, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      Declarative predicate over the alert, in the shared grammar of
      ServiceRadar.Notifications.MatchExpression. An empty object matches every
      alert, which mutes the deployment; that is a deliberate capability, not an
      accident, and it is why writing a silence needs its own permission.
      """
    end

    attribute :starts_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end

    attribute :ends_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Hard end of the window; a silence is never open ended"
    end

    attribute :created_by_user_id, :uuid, allow_nil?: true, public?: true

    attribute :created_by, :string do
      allow_nil? true
      public? true
      description "Free-text principal for a creator that is not a platform user"
    end

    attribute :comment, :string do
      allow_nil? false
      public? true
      description "Required operator justification for withholding notifications"
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :scheduled
      constraints one_of: [:scheduled, :active, :expired, :cancelled]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :created_by_user, ServiceRadar.Identity.User do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :created_by_user_id
    end
  end
end
