defmodule ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluation do
  @moduledoc """
  Persisted SLO compliance, error-budget, and burn-rate state for one evaluation window.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @services_view_check {ActorHasPermission, permission: "services.view"}
  @services_run_check {ActorHasPermission, permission: "services.run"}

  @fields [
    :evaluation_key,
    :slo_id,
    :period_started_at,
    :period_ended_at,
    :evaluated_at,
    :compliance_state,
    :eligible_events,
    :good_events,
    :bad_events,
    :total_windows,
    :good_windows,
    :bad_windows,
    :compliance_basis_points,
    :goal_basis_points,
    :error_budget_total,
    :error_budget_consumed,
    :error_budget_remaining,
    :budget_remaining_basis_points,
    :burn_rate_short,
    :burn_rate_long,
    :projected_exhaustion_at,
    :severity,
    :event_id,
    :alert_id,
    :details,
    :metadata
  ]

  postgres do
    table "service_level_objective_evaluations"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_evaluation_key: "slo_evaluations_evaluation_key_idx"
  end

  state_machine do
    initial_states [:unknown]
    default_initial_state :unknown
    state_attribute :compliance_state

    transitions do
      transition :mark_compliant, from: [:unknown, :at_risk, :noncompliant], to: :compliant
      transition :mark_at_risk, from: [:unknown, :compliant, :noncompliant], to: :at_risk
      transition :mark_noncompliant, from: [:unknown, :compliant, :at_risk], to: :noncompliant
      transition :reset_unknown, from: [:compliant, :at_risk, :noncompliant], to: :unknown
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "service_level_objective_evaluation_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_evaluation_key, action: :by_evaluation_key, args: [:evaluation_key]
    define :list_by_slo, action: :by_slo, args: [:slo_id]
    define :record_evaluation, action: :record
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_evaluation_key do
      argument :evaluation_key, :string, allow_nil?: false
      get? true
      filter expr(evaluation_key == ^arg(:evaluation_key))
    end

    read :by_slo do
      argument :slo_id, :uuid, allow_nil?: false
      filter expr(slo_id == ^arg(:slo_id))
      prepare build(sort: [evaluated_at: :desc])
    end

    read :noncompliant do
      filter expr(compliance_state == :noncompliant)
    end

    create :record do
      accept @fields

      upsert? true
      upsert_identity :unique_evaluation_key
    end

    update :update_budget_state do
      accept List.delete(@fields, :evaluation_key)
    end

    update :mark_compliant do
      accept [:severity, :details, :metadata]
      change transition_state(:compliant)
    end

    update :mark_at_risk do
      accept [:severity, :details, :metadata]
      change transition_state(:at_risk)
    end

    update :mark_noncompliant do
      accept [:severity, :details, :metadata]
      change transition_state(:noncompliant)
    end

    update :reset_unknown do
      accept [:severity, :details, :metadata]
      change transition_state(:unknown)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @services_view_check)

    action_with_permission(
      [
        :record,
        :update_budget_state,
        :mark_compliant,
        :mark_at_risk,
        :mark_noncompliant,
        :reset_unknown
      ],
      @services_run_check
    )
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :evaluation_key, :string, allow_nil?: false, public?: true
    attribute :slo_id, :uuid, allow_nil?: false, public?: true
    attribute :period_started_at, :utc_datetime, allow_nil?: false, public?: true
    attribute :period_ended_at, :utc_datetime, allow_nil?: false, public?: true
    attribute :evaluated_at, :utc_datetime, allow_nil?: false, public?: true

    attribute :compliance_state, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:unknown, :compliant, :at_risk, :noncompliant]
    end

    attribute :eligible_events, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :good_events, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :bad_events, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :total_windows, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :good_windows, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :bad_windows, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :compliance_basis_points, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0, max: 10_000
    end

    attribute :goal_basis_points, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 9_999
    end

    attribute :error_budget_total, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :error_budget_consumed, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :error_budget_remaining, :integer do
      allow_nil? false
      public? true
      default 0
    end

    attribute :budget_remaining_basis_points, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: -10_000, max: 10_000
    end

    attribute :burn_rate_short, :decimal, allow_nil?: true, public?: true
    attribute :burn_rate_long, :decimal, allow_nil?: true, public?: true
    attribute :projected_exhaustion_at, :utc_datetime, allow_nil?: true, public?: true

    attribute :severity, :atom do
      allow_nil? false
      public? true
      default :info
      constraints one_of: [:info, :warning, :critical]
    end

    attribute :event_id, :uuid, allow_nil?: true, public?: true
    attribute :alert_id, :uuid, allow_nil?: true, public?: true

    attribute :details, :map do
      allow_nil? false
      public? true
      default %{}
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
    belongs_to :service_level_objective, ServiceRadar.Monitoring.ServiceLevelObjective do
      source_attribute :slo_id
      destination_attribute :id
      allow_nil? false
      public? true
    end

    belongs_to :alert, ServiceRadar.Monitoring.Alert do
      source_attribute :alert_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_evaluation_key, [:evaluation_key]
  end
end
