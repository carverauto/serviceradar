defmodule ServiceRadar.Monitoring.MonitoredService do
  @moduledoc """
  First-class service target that can be monitored independently of a device.
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
    :service_key,
    :display_name,
    :description,
    :service_kind,
    :protocol,
    :endpoint_url,
    :host,
    :port,
    :path,
    :device_uid,
    :database_name,
    :owner,
    :source,
    :tags,
    :metadata
  ]

  postgres do
    table "monitored_services"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_service_key: "monitored_services_service_key_idx"
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
    table_name "monitored_service_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_service_key, action: :by_service_key, args: [:service_key]
    define :list_active, action: :active
    define :list_by_device, action: :by_device, args: [:device_uid]
    define :create_service, action: :create
    define :update_service, action: :update
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_service_key do
      argument :service_key, :string, allow_nil?: false
      get? true
      filter expr(service_key == ^arg(:service_key))
    end

    read :active do
      filter expr(status == :active)
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
    end

    create :create do
      accept @fields
    end

    update :update do
      accept List.delete(@fields, :service_key)
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
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :service_key, :string, allow_nil?: false, public?: true
    attribute :display_name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :service_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:http, :tcp, :tls, :database, :grpc, :dns, :custom]
    end

    attribute :protocol, :string, allow_nil?: true, public?: true
    attribute :endpoint_url, :string, allow_nil?: true, public?: true
    attribute :host, :string, allow_nil?: true, public?: true

    attribute :port, :integer do
      allow_nil? true
      public? true
      constraints min: 1, max: 65_535
    end

    attribute :path, :string, allow_nil?: true, public?: true
    attribute :device_uid, :string, allow_nil?: true, public?: true
    attribute :database_name, :string, allow_nil?: true, public?: true
    attribute :owner, :string, allow_nil?: true, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :disabled, :retired]
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :manual
      constraints one_of: [:manual, :bulk_import, :discovered, :backfill, :api]
    end

    attribute :tags, :map do
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
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    has_many :group_memberships, ServiceRadar.Monitoring.ServiceGroupMembership do
      destination_attribute :monitored_service_id
      public? true
    end

    has_many :check_instances, ServiceRadar.Monitoring.CheckInstance do
      destination_attribute :monitored_service_id
      public? true
    end

    has_many :latest_check_states, ServiceRadar.Monitoring.LatestCheckState do
      destination_attribute :monitored_service_id
      public? true
    end
  end

  identities do
    identity :unique_service_key, [:service_key]
  end
end
