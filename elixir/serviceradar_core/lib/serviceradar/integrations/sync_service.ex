defmodule ServiceRadar.Integrations.SyncService do
  @moduledoc """
  Sync service registration and health tracking.

  Sync services represent integration runtimes (platform or on-prem) that pull
  device data from external sources and push results through the agent pipeline.
  """

  use Ash.Resource,
    domain: ServiceRadar.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sync_services"
    repo ServiceRadar.Repo

    identity_wheres_to_sql unique_platform_sync: "is_platform_sync = true"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_platform, action: :platform
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :platform do
      description "Platform sync service(s)"
      filter expr(is_platform_sync == true)
    end

    create :create do
      accept [
        :component_id,
        :name,
        :service_type,
        :endpoint,
        :status,
        :is_platform_sync,
        :capabilities,
        :last_heartbeat_at
      ]

      change fn changeset, _context ->
        case changeset.tenant do
          nil -> changeset
          tenant_id -> Ash.Changeset.force_change_attribute(changeset, :tenant_id, tenant_id)
        end
      end
    end

    update :update do
      accept [
        :name,
        :endpoint,
        :status,
        :capabilities,
        :last_heartbeat_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :component_id, :string do
      allow_nil? false
      constraints min_length: 1, max_length: 255
      description "Stable sync service identifier (matches onboarding component_id)"
    end

    attribute :name, :string do
      allow_nil? false
      constraints min_length: 1, max_length: 255
    end

    attribute :service_type, :atom do
      allow_nil? false
      constraints one_of: [:saas, :on_prem]
    end

    attribute :endpoint, :string

    attribute :status, :atom do
      allow_nil? false
      default :offline
      constraints one_of: [:online, :offline, :degraded]
    end

    attribute :is_platform_sync, :boolean do
      allow_nil? false
      default false
    end

    attribute :capabilities, {:array, :string} do
      default []
    end

    attribute :last_heartbeat_at, :utc_datetime

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_platform_sync, [:tenant_id], where: expr(is_platform_sync == true)
    identity :unique_component_id, [:tenant_id, :component_id]
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end
end
