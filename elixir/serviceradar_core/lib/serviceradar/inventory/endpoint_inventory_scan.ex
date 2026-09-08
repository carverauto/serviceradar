defmodule ServiceRadar.Inventory.EndpointInventoryScan do
  @moduledoc """
  Endpoint package/SBOM inventory scan metadata.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "endpoint_inventory_scans"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_agent_scan, action: :by_agent_scan, args: [:agent_id, :scan_id]
    define :get_current_by_agent, action: :current_by_agent, args: [:agent_id]
    define :list_current_by_device, action: :current_by_device, args: [:device_uid]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :device_uid,
        :agent_id,
        :scan_id,
        :collector_name,
        :collector_version,
        :state,
        :coverage_state,
        :package_count,
        :enabled_sources,
        :manager_counts,
        :source_summaries,
        :artifact_count,
        :current,
        :last_successful_scan_at,
        :last_scan_at,
        :last_changed_scan_at,
        :ingested_at,
        :package_set_hash,
        :artifact_hash,
        :hash_algorithm,
        :upload_reason,
        :server_package_set_hash,
        :package_set_hash_mismatch,
        :unchanged_scan_count,
        :reconcile_floor_due,
        :metadata
      ]
    end

    update :update do
      accept [
        :device_uid,
        :collector_name,
        :collector_version,
        :state,
        :coverage_state,
        :package_count,
        :enabled_sources,
        :manager_counts,
        :source_summaries,
        :artifact_count,
        :current,
        :last_successful_scan_at,
        :last_scan_at,
        :last_changed_scan_at,
        :ingested_at,
        :package_set_hash,
        :artifact_hash,
        :hash_algorithm,
        :upload_reason,
        :server_package_set_hash,
        :package_set_hash_mismatch,
        :unchanged_scan_count,
        :reconcile_floor_due,
        :metadata
      ]
    end

    read :by_agent_scan do
      argument :agent_id, :string, allow_nil?: false
      argument :scan_id, :string, allow_nil?: false
      get? true
      filter expr(agent_id == ^arg(:agent_id) and scan_id == ^arg(:scan_id))
    end

    read :current_by_agent do
      argument :agent_id, :string, allow_nil?: false
      get? true
      filter expr(agent_id == ^arg(:agent_id) and current == true)
    end

    read :current_by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid) and current == true)
      prepare build(sort: [last_scan_at: :desc, agent_id: :asc])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :device_uid, :string do
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :scan_id, :string do
      allow_nil? false
      public? true
    end

    attribute :collector_name, :string do
      public? true
    end

    attribute :collector_version, :string do
      public? true
    end

    attribute :state, :string do
      allow_nil? false
      default "not_scanned"
      public? true
    end

    attribute :coverage_state, :string do
      allow_nil? false
      default "not_scanned"
      public? true
    end

    attribute :package_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :enabled_sources, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :manager_counts, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :source_summaries, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :artifact_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :current, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :last_successful_scan_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_scan_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_changed_scan_at, :utc_datetime_usec do
      public? true
    end

    attribute :ingested_at, :utc_datetime_usec do
      public? true
    end

    attribute :package_set_hash, :string do
      public? true
    end

    attribute :artifact_hash, :string do
      public? true
    end

    attribute :hash_algorithm, :string do
      public? true
    end

    attribute :upload_reason, :string do
      public? true
    end

    attribute :server_package_set_hash, :string do
      public? true
    end

    attribute :package_set_hash_mismatch, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :unchanged_scan_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :reconcile_floor_due, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      define_attribute? false
      allow_nil? true
      public? true
    end

    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_id
      destination_attribute :uid
      define_attribute? false
      allow_nil? true
      public? true
    end

    has_many :artifacts, ServiceRadar.Inventory.EndpointInventoryArtifact do
      source_attribute :id
      destination_attribute :scan_ref
      public? true
    end

    has_many :packages, ServiceRadar.Inventory.EndpointInventoryPackage do
      source_attribute :id
      destination_attribute :scan_ref
      public? true
    end
  end

  calculations do
    calculate :freshness_verdict,
              :string,
              expr(
                fragment(
                  "CASE WHEN ? IS NULL THEN 'unknown' WHEN ? > NOW() - INTERVAL '26 hours' THEN 'fresh' ELSE 'stale' END",
                  last_successful_scan_at,
                  last_successful_scan_at
                )
              ) do
      public? true
    end
  end

  identities do
    identity :unique_agent_scan, [:agent_id, :scan_id]
  end
end
