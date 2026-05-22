defmodule ServiceRadar.Monitoring.ServiceLevelObjective do
  @moduledoc """
  Operator-defined objective over an SLI, target set, and compliance period.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @services_view_check {ActorHasPermission, permission: "services.view"}
  @services_create_check {ActorHasPermission, permission: "services.create"}
  @services_update_check {ActorHasPermission, permission: "services.update"}
  @services_run_check {ActorHasPermission, permission: "services.run"}

  @fields [
    :slo_key,
    :name,
    :description,
    :sli_id,
    :target_set_type,
    :service_group_id,
    :target_query,
    :target_filters,
    :slo_kind,
    :goal_basis_points,
    :compliance_period_type,
    :rolling_period_days,
    :calendar_period,
    :measurement_window_seconds,
    :burn_rate_policy,
    :alert_policy,
    :owner,
    :metadata
  ]

  postgres do
    table "service_level_objectives"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_slo_key: "service_level_objectives_slo_key_idx"
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft
    state_attribute :status

    transitions do
      transition :activate, from: [:draft, :disabled], to: :active
      transition :disable, from: [:active], to: :disabled
      transition :archive, from: [:draft, :active, :disabled], to: :archived
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "service_level_objective_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_slo_key, action: :by_slo_key, args: [:slo_key]
    define :list_active, action: :active
    define :list_by_owner, action: :by_owner, args: [:owner]
    define :create_objective, action: :create
    define :update_objective, action: :update
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_slo_key do
      argument :slo_key, :string, allow_nil?: false
      get? true
      filter expr(slo_key == ^arg(:slo_key))
    end

    read :active do
      filter expr(status == :active)
    end

    read :by_owner do
      argument :owner, :string, allow_nil?: false
      filter expr(owner == ^arg(:owner))
    end

    create :create do
      accept @fields
    end

    update :update do
      accept List.delete(@fields, :slo_key)
    end

    update :record_evaluation_summary do
      accept [
        :last_evaluated_at,
        :last_compliance_state,
        :last_budget_remaining_basis_points,
        :last_burn_rate
      ]
    end

    update :activate do
      accept []
      change transition_state(:active)
    end

    update :disable do
      accept []
      change transition_state(:disabled)
    end

    update :archive do
      accept []
      change transition_state(:archived)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @services_view_check)
    action_type_with_permission(:create, @services_create_check)
    action_with_permission([:update, :activate, :disable, :archive], @services_update_check)
    action_with_permission(:record_evaluation_summary, @services_run_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :slo_key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true
    attribute :sli_id, :uuid, allow_nil?: false, public?: true

    attribute :target_set_type, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :service_group,
                    :service_srql,
                    :device_srql,
                    :explicit_services,
                    :explicit_devices
                  ]
    end

    attribute :service_group_id, :uuid, allow_nil?: true, public?: true
    attribute :target_query, :string, allow_nil?: true, public?: true

    attribute :target_filters, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :slo_kind, :atom do
      allow_nil? false
      public? true
      default :request_based
      constraints one_of: [:request_based, :window_based]
    end

    attribute :goal_basis_points, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 9_999
      description "SLO target in basis points. 9990 is 99.90%; 10000 is rejected."
    end

    attribute :compliance_period_type, :atom do
      allow_nil? false
      public? true
      default :rolling
      constraints one_of: [:rolling, :calendar]
    end

    attribute :rolling_period_days, :integer do
      allow_nil? true
      public? true
      default 30
      constraints min: 1, max: 30
    end

    attribute :calendar_period, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:day, :week, :month, :quarter]
    end

    attribute :measurement_window_seconds, :integer do
      allow_nil? true
      public? true
      constraints min: 60
    end

    attribute :burn_rate_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :alert_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :owner, :string, allow_nil?: true, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :active, :disabled, :archived]
    end

    attribute :last_evaluated_at, :utc_datetime, allow_nil?: true, public?: true

    attribute :last_compliance_state, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:unknown, :compliant, :at_risk, :noncompliant]
    end

    attribute :last_budget_remaining_basis_points, :integer do
      allow_nil? true
      public? true
      constraints min: -10_000, max: 10_000
    end

    attribute :last_burn_rate, :decimal, allow_nil?: true, public?: true

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :service_level_indicator, ServiceRadar.Monitoring.ServiceLevelIndicator do
      source_attribute :sli_id
      destination_attribute :id
      allow_nil? false
      public? true
    end

    belongs_to :service_group, ServiceRadar.Monitoring.ServiceGroup do
      source_attribute :service_group_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    has_many :evaluations, ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluation do
      destination_attribute :slo_id
      public? true
    end
  end

  identities do
    identity :unique_slo_key, [:slo_key]
  end
end
