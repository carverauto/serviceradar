defmodule ServiceRadar.Inventory.BumblebeeDevicePosture do
  @moduledoc """
  Current Bumblebee posture for an agent and its associated canonical device.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bumblebee_device_postures"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_agent, action: :by_agent, args: [:agent_id]
    define :list_by_device, action: :by_device, args: [:device_uid]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :device_uid,
        :agent_id,
        :run_id,
        :catalog_snapshot_ref,
        :scanner_version,
        :state,
        :coverage_state,
        :attempted_root_count,
        :scanned_root_count,
        :skipped_root_count,
        :root_covered,
        :skipped_roots,
        :risk_score,
        :highest_severity,
        :active_finding_count,
        :last_successful_scan_at,
        :last_scan_at,
        :metadata
      ]
    end

    update :update do
      accept [
        :device_uid,
        :run_id,
        :catalog_snapshot_ref,
        :scanner_version,
        :state,
        :coverage_state,
        :attempted_root_count,
        :scanned_root_count,
        :skipped_root_count,
        :root_covered,
        :skipped_roots,
        :risk_score,
        :highest_severity,
        :active_finding_count,
        :last_successful_scan_at,
        :last_scan_at,
        :metadata
      ]
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      get? true
      filter expr(agent_id == ^arg(:agent_id))
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [updated_at: :desc, agent_id: :asc])
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

    attribute :run_id, :string do
      public? true
    end

    attribute :catalog_snapshot_ref, :string do
      public? true
    end

    attribute :scanner_version, :string do
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

    attribute :attempted_root_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :scanned_root_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :skipped_root_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :root_covered, :boolean do
      public? true
    end

    attribute :skipped_roots, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :risk_score, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :highest_severity, :string do
      public? true
    end

    attribute :active_finding_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :last_successful_scan_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_scan_at, :utc_datetime_usec do
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
  end

  identities do
    identity :unique_agent, [:agent_id]
  end
end
