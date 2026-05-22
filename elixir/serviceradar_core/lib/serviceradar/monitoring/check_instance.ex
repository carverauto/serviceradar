defmodule ServiceRadar.Monitoring.CheckInstance do
  @moduledoc """
  Materialized executable check for a monitored service or device target.
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
    :check_key,
    :monitoring_binding_id,
    :monitored_service_id,
    :device_uid,
    :descriptor_id,
    :descriptor_version,
    :capability_kind,
    :plugin_package_id,
    :vantage_kind,
    :vantage_id,
    :agent_id,
    :target_snapshot,
    :credential_policy_snapshot,
    :event_policy_snapshot,
    :last_materialized_at,
    :metadata
  ]

  postgres do
    table "check_instances"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_check_key: "check_instances_check_key_idx"
  end

  state_machine do
    initial_states [:active]
    default_initial_state :active
    state_attribute :status

    transitions do
      transition :activate, from: [:disabled], to: :active
      transition :disable, from: [:active], to: :disabled
      transition :retire, from: [:active, :disabled], to: :retired
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "check_instance_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_check_key, action: :by_check_key, args: [:check_key]
    define :list_active, action: :active
    define :list_by_binding, action: :by_binding, args: [:monitoring_binding_id]
    define :list_by_service, action: :by_service, args: [:monitored_service_id]
    define :materialize, action: :materialize
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_check_key do
      argument :check_key, :string, allow_nil?: false
      get? true
      filter expr(check_key == ^arg(:check_key))
    end

    read :active do
      filter expr(status == :active)
    end

    read :by_binding do
      argument :monitoring_binding_id, :uuid, allow_nil?: false
      filter expr(monitoring_binding_id == ^arg(:monitoring_binding_id))
    end

    read :by_service do
      argument :monitored_service_id, :uuid, allow_nil?: false
      filter expr(monitored_service_id == ^arg(:monitored_service_id))
    end

    create :materialize do
      upsert? true
      upsert_identity :unique_check_key
      upsert_fields List.delete(@fields, :check_key) ++ [:updated_at]
      accept @fields
    end

    update :update do
      accept List.delete(@fields, :check_key)
    end

    update :activate do
      accept []
      change transition_state(:active)
    end

    update :disable do
      accept []
      change transition_state(:disabled)
    end

    update :retire do
      accept []
      change transition_state(:retired)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @services_view_check)
    action_type_with_permission(:create, @services_create_check)
    action_with_permission([:update, :activate, :disable, :retire], @services_update_check)
    action_with_permission(:materialize, @services_run_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :check_key, :string, allow_nil?: false, public?: true
    attribute :monitoring_binding_id, :uuid, allow_nil?: true, public?: true
    attribute :monitored_service_id, :uuid, allow_nil?: true, public?: true
    attribute :device_uid, :string, allow_nil?: true, public?: true
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

    attribute :vantage_kind, :atom do
      allow_nil? false
      public? true
      default :agent
      constraints one_of: [:agent, :gateway, :control_plane, :external]
    end

    attribute :vantage_id, :string, allow_nil?: true, public?: true
    attribute :agent_id, :string, allow_nil?: true, public?: true

    attribute :target_snapshot, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :credential_policy_snapshot, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :event_policy_snapshot, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :disabled, :retired]
    end

    attribute :last_materialized_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :monitoring_binding, ServiceRadar.Monitoring.MonitoringBinding do
      source_attribute :monitoring_binding_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    belongs_to :monitored_service, ServiceRadar.Monitoring.MonitoredService do
      source_attribute :monitored_service_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_id
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    belongs_to :plugin_package, ServiceRadar.Plugins.PluginPackage do
      source_attribute :plugin_package_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    has_one :latest_state, ServiceRadar.Monitoring.LatestCheckState do
      destination_attribute :check_instance_id
      public? true
    end
  end

  identities do
    identity :unique_check_key, [:check_key]
  end
end
