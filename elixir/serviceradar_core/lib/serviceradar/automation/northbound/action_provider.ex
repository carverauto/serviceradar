defmodule ServiceRadar.Automation.Northbound.ActionProvider do
  @moduledoc """
  Configured source of northbound actions.

  Providers can be native integrations, approved Wasm plugin packages, or
  first-party adapters such as Ansible. Provider records carry health and
  approval metadata; action descriptors carry the launch contract.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Northbound,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "northbound.actions.view"}
  @launch_check {ActorHasPermission, permission: "northbound.actions.launch"}
  @manage_check {ActorHasPermission, permission: "northbound.actions.manage"}

  @fields [
    :name,
    :description,
    :provider_type,
    :source_ref,
    :plugin_package_id,
    :status,
    :health_status,
    :last_health_at,
    :last_health_summary,
    :approved_capabilities,
    :credential_requirements,
    :metadata
  ]

  @launch_read_fields [:id, :name, :provider_type, :status]

  postgres do
    table "northbound_action_providers"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_provider_source: "northbound_action_providers_type_source_uidx"

    references do
      reference :plugin_package, on_delete: :nilify
    end
  end

  state_machine do
    initial_states [:staged]
    default_initial_state :staged
    state_attribute :status

    transitions do
      transition :activate, from: [:staged, :disabled], to: :active
      transition :disable, from: [:staged, :active, :unhealthy], to: :disabled
      transition :mark_unhealthy, from: [:active], to: :unhealthy
      transition :mark_recovered, from: [:unhealthy], to: :active
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "northbound_action_provider_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :last_health_at, :last_health_summary]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_source, action: :by_source, args: [:provider_type, :source_ref]
    define :get_by_plugin_package, action: :by_plugin_package, args: [:plugin_package_id]
    define :list_active, action: :active
    define :get_launch_candidate_by_id, action: :launch_candidate_by_id, args: [:id]
    define :list_launch_candidates_by_ids, action: :launch_candidates_by_ids, args: [:ids]
    define :create_provider, action: :create
    define :update_provider, action: :update
    define :activate, action: :activate
    define :disable, action: :disable
    define :mark_unhealthy, action: :mark_unhealthy
    define :mark_recovered, action: :mark_recovered
    define :record_health, action: :record_health
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

    read :active do
      filter expr(status == :active)
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :by_source do
      argument :provider_type, :atom, allow_nil?: false
      argument :source_ref, :string, allow_nil?: false

      get? true
      filter expr(provider_type == ^arg(:provider_type) and source_ref == ^arg(:source_ref))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :by_plugin_package do
      argument :plugin_package_id, :uuid, allow_nil?: false

      get? true
      filter expr(plugin_package_id == ^arg(:plugin_package_id))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :launch_candidate_by_id do
      argument :id, :uuid, allow_nil?: false
      get? true

      filter expr(id == ^arg(:id) and provider_type != :ansible)
      prepare build(select: @launch_read_fields)
    end

    read :launch_candidates_by_ids do
      argument :ids, {:array, :uuid}, allow_nil?: false

      filter expr(id in ^arg(:ids) and status == :active and provider_type != :ansible)
      prepare build(select: @launch_read_fields)
    end

    create :create do
      accept List.delete(@fields, :status)
    end

    update :update do
      accept [
        :name,
        :description,
        :source_ref,
        :plugin_package_id,
        :approved_capabilities,
        :credential_requirements,
        :metadata
      ]
    end

    update :activate do
      change transition_state(:active)
    end

    update :disable do
      change transition_state(:disabled)
    end

    update :mark_unhealthy do
      accept [:last_health_summary]
      change set_attribute(:health_status, :unhealthy)
      change set_attribute(:last_health_at, &DateTime.utc_now/0)
      change transition_state(:unhealthy)
    end

    update :mark_recovered do
      accept [:last_health_summary]
      change set_attribute(:health_status, :ok)
      change set_attribute(:last_health_at, &DateTime.utc_now/0)
      change transition_state(:active)
    end

    update :record_health do
      accept [:health_status, :last_health_summary]
      change set_attribute(:last_health_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :active], @view_check)
    action_with_permission([:by_source, :by_plugin_package], @view_check)
    action_with_permission([:launch_candidate_by_id, :launch_candidates_by_ids], @launch_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)

    action_with_permission(
      [:activate, :disable, :mark_unhealthy, :mark_recovered, :record_health],
      @manage_check
    )
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :provider_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:native, :wasm_plugin, :ansible]
    end

    attribute :source_ref, :string do
      allow_nil? true
      public? true
      description "Provider-owned stable reference, such as a native adapter key or plugin id"
    end

    attribute :plugin_package_id, :uuid, allow_nil?: true, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :staged
      constraints one_of: [:staged, :active, :disabled, :unhealthy]
    end

    attribute :health_status, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:unknown, :ok, :degraded, :unhealthy, :unauthorized]
    end

    attribute :last_health_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :last_health_summary, :string, allow_nil?: true, public?: true

    attribute :approved_capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :credential_requirements, :map do
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
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :plugin_package_id
    end

    has_many :descriptors, ServiceRadar.Automation.Northbound.ActionDescriptor do
      destination_attribute :provider_id
    end
  end

  identities do
    identity :unique_provider_source, [:provider_type, :source_ref]
  end
end
