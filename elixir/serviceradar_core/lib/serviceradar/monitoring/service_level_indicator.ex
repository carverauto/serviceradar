defmodule ServiceRadar.Monitoring.ServiceLevelIndicator do
  @moduledoc """
  Definition of a service-level indicator used by service SLOs.
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

  @fields [
    :sli_key,
    :name,
    :description,
    :sli_type,
    :source_type,
    :measurement_kind,
    :good_statuses,
    :metric_name,
    :threshold_operator,
    :threshold_value,
    :threshold_unit,
    :query_template,
    :numerator_query,
    :denominator_query,
    :window_config,
    :metadata
  ]

  postgres do
    table "service_level_indicators"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_sli_key: "service_level_indicators_sli_key_idx"
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
    table_name "service_level_indicator_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_sli_key, action: :by_sli_key, args: [:sli_key]
    define :list_active, action: :active
    define :create_indicator, action: :create
    define :update_indicator, action: :update
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_sli_key do
      argument :sli_key, :string, allow_nil?: false
      get? true
      filter expr(sli_key == ^arg(:sli_key))
    end

    read :active do
      filter expr(status == :active)
    end

    create :create do
      accept @fields
    end

    update :update do
      accept List.delete(@fields, :sli_key)
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
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :sli_key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :sli_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:availability, :success_ratio, :latency, :freshness, :custom_srql]
    end

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      default :check_state
      constraints one_of: [:check_state, :check_metric, :event, :rollup, :srql]
    end

    attribute :measurement_kind, :atom do
      allow_nil? false
      public? true
      default :request
      constraints one_of: [:request, :window]
    end

    attribute :good_statuses, {:array, :atom} do
      allow_nil? false
      public? true
      default [:ok]
      constraints items: [one_of: [:ok, :warning, :unknown, :critical]]
    end

    attribute :metric_name, :string, allow_nil?: true, public?: true

    attribute :threshold_operator, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:lt, :lte, :gt, :gte, :eq, :neq]
    end

    attribute :threshold_value, :decimal, allow_nil?: true, public?: true
    attribute :threshold_unit, :string, allow_nil?: true, public?: true
    attribute :query_template, :string, allow_nil?: true, public?: true
    attribute :numerator_query, :string, allow_nil?: true, public?: true
    attribute :denominator_query, :string, allow_nil?: true, public?: true

    attribute :window_config, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :active, :disabled, :archived]
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
    has_many :service_level_objectives, ServiceRadar.Monitoring.ServiceLevelObjective do
      destination_attribute :sli_id
      public? true
    end
  end

  identities do
    identity :unique_sli_key, [:sli_key]
  end
end
