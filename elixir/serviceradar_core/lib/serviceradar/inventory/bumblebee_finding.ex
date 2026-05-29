defmodule ServiceRadar.Inventory.BumblebeeFinding do
  @moduledoc """
  Current and bounded historical Bumblebee exposure finding state.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bumblebee_findings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_active_by_device, action: :active_by_device, args: [:device_uid]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :device_uid,
        :agent_id,
        :run_id,
        :finding_id,
        :catalog_id,
        :catalog_snapshot_ref,
        :scanner_version,
        :severity,
        :risk_score,
        :ecosystem,
        :package_name,
        :package_version,
        :evidence,
        :confidence,
        :status,
        :first_seen_at,
        :last_seen_at,
        :resolved_at,
        :metadata
      ]
    end

    update :update do
      accept [
        :device_uid,
        :run_id,
        :catalog_id,
        :catalog_snapshot_ref,
        :scanner_version,
        :severity,
        :risk_score,
        :ecosystem,
        :package_name,
        :package_version,
        :evidence,
        :confidence,
        :status,
        :last_seen_at,
        :resolved_at,
        :metadata
      ]
    end

    read :active_by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid) and status == "active")
      prepare build(sort: [risk_score: :desc, severity: :desc, last_seen_at: :desc])
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

    attribute :finding_id, :string do
      allow_nil? false
      public? true
    end

    attribute :catalog_id, :string do
      public? true
    end

    attribute :catalog_snapshot_ref, :string do
      public? true
    end

    attribute :scanner_version, :string do
      public? true
    end

    attribute :severity, :string do
      allow_nil? false
      public? true
    end

    attribute :risk_score, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :ecosystem, :string do
      public? true
    end

    attribute :package_name, :string do
      public? true
    end

    attribute :package_version, :string do
      public? true
    end

    attribute :evidence, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :confidence, :string do
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      default "active"
      public? true
    end

    attribute :first_seen_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      public? true
    end

    attribute :resolved_at, :utc_datetime_usec do
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
    identity :unique_agent_finding, [:agent_id, :finding_id]
  end
end
