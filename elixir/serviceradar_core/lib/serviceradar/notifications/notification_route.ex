defmodule ServiceRadar.Notifications.NotificationRoute do
  @moduledoc """
  Binds alerts to an escalation policy by declarative predicate (design D6, G10).

  A route answers one question: *given this alert, which ladder should page, and
  how quietly?* Routes are evaluated in ascending `priority`, then by `id` for a
  stable tiebreak, over the enabled set only - the same order as the partial
  index `notification_routes_priority_idx`.

  ## Alertmanager `continue` semantics

  `continue` is false by default, which means **the first matching route wins
  and evaluation stops**. Setting it true lets evaluation fall through to lower
  priority routes so one alert can reach several ladders. This is the same knob
  Alertmanager exposes under the same name, deliberately, so an operator's
  existing mental model transfers.

  An alert that matches zero enabled routes is not silently dropped: the
  dispatcher records a `NotificationDelivery` with
  `suppression_reason: :no_matching_route` (design D5), which is what makes the
  unrouted alert visible instead of invisible.

  ## match_expression is data, never code

  `match_expression` is a declarative predicate document over alert attributes.
  Its **shape** is validated at save time and never compiled, `eval`ed, or
  turned into atoms, per design D9. Two validations cover it, each owning one
  half:

  - `ServiceRadar.Notifications.MatchExpression` owns the grammar - the allowed
    combinators, the allowed operators, and the syntax of a field path. It is
    shared verbatim with `NotificationSilence.matchers`, so a silence and the
    route that created it can never drift into two dialects.
  - `ServiceRadar.Notifications.Validations.MatchFieldAllowList` owns the field
    paths this route's evaluation context can resolve. That list is published by
    `ServiceRadar.Notifications.MatchExpression.Fields`, which is the complete
    matchable surface of a route in one place a reviewer can read.

  Keeping the allow-list out of the grammar is deliberate: the resolvable set
  differs between routing and suppression, and the grammar module says so.
  Keeping it out of *this* module is equally deliberate - the save-time
  validator here and the dispatch-time evaluator
  (`ServiceRadar.Notifications.MatchExpression.Evaluator`, driven by
  `ServiceRadar.Notifications.Router`) must agree exactly, because a path this
  resource admits but the evaluator cannot resolve is a route that saves
  cleanly and matches nothing, forever, silently. Both read
  `MatchExpression.Fields`, so they cannot drift.

  An empty document (`%{}`, the default) matches every alert, which is the
  correct shape for a catch-all route parked at a high `priority` number.

  ## dedupe_key_template is an OPTIONAL override

  When `dedupe_key_template` is nil - the normal case - the engine uses the
  existing incident identity, the composite `{rule_id, group_key}` already
  maintained by `ServiceRadar.Observability.StatefulAlertRuleState` and
  `AlertLifecycle`. This resource does **not** re-author deduplication; per
  design D6 the notification platform *consumes* the incident identity,
  `cooldown_seconds`, and `renotify_seconds` rather than inventing a second one.
  The template exists only for the cases rule grouping does not cover.

  Likewise the cadence knobs here can only make an incident **quieter**. The
  rule's `renotify_seconds` is the floor; a route may narrow a cadence, never
  widen it.

  ## Grouping

  `group_wait_seconds` holds the first notification for a new group so related
  alerts arrive as one page; `group_interval_seconds` bounds how often an
  already-notified group may notify again; `throttle_seconds` is the route-level
  rate limit on repeats. All three are seconds and all three are optional
  beyond their defaults.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.MatchExpression
  alias ServiceRadar.Notifications.MatchExpression.Fields
  alias ServiceRadar.Notifications.Validations.MatchFieldAllowList
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "notifications.routes.view"}
  @manage_check {ActorHasPermission, permission: "notifications.routes.manage"}

  # The complete matchable surface, read from the module the dispatch-time
  # evaluator also reads. Everything else is rejected at save time. The list
  # itself lives in ServiceRadar.Notifications.MatchExpression.Fields so that a
  # path can never be admitted here and be unresolvable there; see that module
  # for why that particular drift is the expensive one.
  @match_fields Fields.route_fields()
  @match_field_prefixes Fields.route_field_prefixes()

  @fields [
    :name,
    :description,
    :enabled,
    :priority,
    :match_expression,
    :escalation_policy_id,
    :schedule_id,
    :dedupe_key_template,
    :throttle_seconds,
    :group_wait_seconds,
    :group_interval_seconds,
    :continue
  ]

  postgres do
    table "notification_routes"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_name: "notification_routes_name_uidx"

    references do
      reference :escalation_policy, on_delete: :restrict
      reference :schedule, on_delete: :nilify
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "notification_route_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  json_api do
    type "notification_route"

    routes do
      base "/notification-routes"

      index :read
      post :create
      patch :update
      patch :enable, route: "/:id/enable"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_name, action: :by_name, args: [:name]
    define :list_enabled, action: :enabled
    define :list_for_policy, action: :for_policy, args: [:escalation_policy_id]
    define :create_route, action: :create
    define :update_route, action: :update
    define :enable, action: :enable
    define :disable, action: :disable
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

    # Evaluation order. Ascending priority with `id` as the stable tiebreak,
    # matching notification_routes_priority_idx so the scan stays index-ordered.
    read :enabled do
      filter expr(enabled == true)

      prepare build(
                sort: [priority: :asc, id: :asc],
                select: [:id, :inserted_at, :updated_at | @fields]
              )
    end

    # Answers "what still routes to this ladder?" before a policy is retired.
    read :for_policy do
      argument :escalation_policy_id, :uuid, allow_nil?: false

      filter expr(escalation_policy_id == ^arg(:escalation_policy_id))

      prepare build(
                sort: [priority: :asc, id: :asc],
                select: [:id, :inserted_at, :updated_at | @fields]
              )
    end

    create :create do
      accept @fields
    end

    # `enabled` is deliberately not updatable here: toggling a route on or off
    # is its own auditable act, so it goes through :enable / :disable.
    update :update do
      accept List.delete(@fields, :enabled)
    end

    update :enable do
      change set_attribute(:enabled, true)
    end

    update :disable do
      change set_attribute(:enabled, false)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_name, :enabled, :for_policy], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:enable, :disable], @manage_check)
  end

  validations do
    validate {MatchExpression, attribute: :match_expression, reject_empty_equals?: true}

    validate {MatchFieldAllowList,
              attribute: :match_expression,
              fields: @match_fields,
              field_prefixes: @match_field_prefixes}
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "Only enabled routes are evaluated"
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 100
      description "Evaluation order, ascending. Lower numbers are considered first"
    end

    attribute :match_expression, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      Declarative predicate document over alert attributes. Shape validated at \
      save time against the allowed combinators, operators, and field paths; \
      never evaluated as code. An empty document matches every alert.\
      """
    end

    attribute :escalation_policy_id, :uuid do
      allow_nil? false
      public? true
      description "Ladder this route hands the alert to"
    end

    attribute :schedule_id, :uuid do
      allow_nil? true
      public? true
      description "Optional time window; outside it the dispatch is suppressed with :schedule"
    end

    attribute :dedupe_key_template, :string do
      allow_nil? true
      public? true

      description """
      OPTIONAL override. When nil the engine uses the existing \
      {rule_id, group_key} incident identity; deduplication is not re-authored \
      here. Set this only for cases the rule grouping does not cover.\
      """
    end

    attribute :throttle_seconds, :integer do
      allow_nil? true
      public? true
      constraints min: 0
      description "Minimum seconds between repeat notifications for the same dedupe key"
    end

    attribute :group_wait_seconds, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
      description "Hold a new group this long so related alerts arrive as one notification"
    end

    attribute :group_interval_seconds, :integer do
      allow_nil? true
      public? true
      constraints min: 0
      description "Minimum seconds before an already-notified group may notify again"
    end

    attribute :continue, :boolean do
      allow_nil? false
      public? true
      default false

      description """
      Alertmanager semantics. When false the first matching route wins and \
      evaluation stops; when true evaluation falls through to lower priority \
      routes.\
      """
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :escalation_policy, ServiceRadar.Notifications.NotificationEscalationPolicy do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :escalation_policy_id
    end

    belongs_to :schedule, ServiceRadar.Notifications.NotificationSchedule do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :schedule_id
    end

    has_many :deliveries, ServiceRadar.Notifications.NotificationDelivery do
      destination_attribute :route_id
      public? true
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
