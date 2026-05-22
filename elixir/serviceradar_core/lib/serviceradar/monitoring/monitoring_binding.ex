defmodule ServiceRadar.Monitoring.MonitoringBinding do
  @moduledoc """
  Desired monitoring configuration that binds a check descriptor to a target set.
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
    :name,
    :description,
    :descriptor_id,
    :descriptor_version,
    :capability_kind,
    :plugin_package_id,
    :target_set_type,
    :service_group_id,
    :target_query,
    :target_filters,
    :agent_scope_type,
    :agent_scope_value,
    :interval_seconds,
    :timeout_seconds,
    :credential_policy,
    :threshold_policy,
    :event_policy,
    :alert_policy,
    :metadata
  ]

  postgres do
    table "monitoring_bindings"
    repo ServiceRadar.Repo
    schema "platform"
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
    table_name "monitoring_binding_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active, action: :active
    define :list_by_descriptor, action: :by_descriptor, args: [:descriptor_id]
    define :create_binding, action: :create
    define :update_binding, action: :update
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active do
      filter expr(status == :active)
    end

    read :by_descriptor do
      argument :descriptor_id, :string, allow_nil?: false
      filter expr(descriptor_id == ^arg(:descriptor_id))
    end

    create :create do
      accept @fields
    end

    update :update do
      accept @fields
    end

    update :record_reconcile do
      accept [:last_reconcile_summary]
      change set_attribute(:last_reconciled_at, &DateTime.utc_now/0)
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
    action_with_permission(:record_reconcile, @services_run_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true
    attribute :descriptor_id, :string, allow_nil?: false, public?: true

    attribute :descriptor_version, :string do
      allow_nil? false
      public? true
      default "1.0.0"
    end

    attribute :capability_kind, :atom do
      allow_nil? false
      public? true
      default :plugin
      constraints one_of: [:plugin, :builtin]
    end

    attribute :plugin_package_id, :uuid, allow_nil?: true, public?: true

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

    attribute :agent_scope_type, :atom do
      allow_nil? false
      public? true
      default :any
      constraints one_of: [:any, :agent, :gateway, :partition, :edge_site]
    end

    attribute :agent_scope_value, :string, allow_nil?: true, public?: true

    attribute :interval_seconds, :integer do
      allow_nil? false
      public? true
      default 60
      constraints min: 5
    end

    attribute :timeout_seconds, :integer do
      allow_nil? false
      public? true
      default 10
      constraints min: 1
    end

    attribute :credential_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :threshold_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :event_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :alert_policy, :map do
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

    attribute :last_reconciled_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :last_reconcile_summary, :map do
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
    belongs_to :plugin_package, ServiceRadar.Plugins.PluginPackage do
      source_attribute :plugin_package_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    belongs_to :service_group, ServiceRadar.Monitoring.ServiceGroup do
      source_attribute :service_group_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    has_many :check_instances, ServiceRadar.Monitoring.CheckInstance do
      destination_attribute :monitoring_binding_id
      public? true
    end
  end
end
