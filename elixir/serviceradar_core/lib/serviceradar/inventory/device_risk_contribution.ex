defmodule ServiceRadar.Inventory.DeviceRiskContribution do
  @moduledoc """
  Source-specific risk contribution for a canonical device.

  The inventory-visible `ocsf_devices.risk_score` is derived from active
  contributions by `ServiceRadar.Inventory.DeviceRiskReducer`; ingestion sources
  should update their own contribution instead of writing the device score
  directly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  @fields [
    :device_uid,
    :source,
    :source_ref,
    :score,
    :risk_level_id,
    :risk_level,
    :reason,
    :active,
    :occurred_at,
    :resolved_at,
    :metadata
  ]

  postgres do
    table "device_risk_contributions"
    repo ServiceRadar.Repo
    schema "platform"
  end

  paper_trail do
    primary_key_type :uuid
    table_name "device_risk_contribution_versions"
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_uid]
    define :list_active_by_device, action: :active_by_device, args: [:device_uid]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields
    end

    update :update do
      accept @fields -- [:device_uid, :source, :source_ref]
    end

    update :resolve do
      accept [:resolved_at, :reason, :metadata]
      change set_attribute(:active, false)
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [active: :desc, score: :desc, source: :asc])
    end

    read :active_by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid) and active == true)
      prepare build(sort: [score: :desc, source: :asc])
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
      allow_nil? false
      public? true
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :source_ref, :string do
      allow_nil? false
      default "current"
      public? true
      constraints max_length: 128
    end

    attribute :score, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 100
    end

    attribute :risk_level_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :risk_level, :string do
      allow_nil? false
      public? true
    end

    attribute :reason, :string do
      public? true
      constraints max_length: 512
    end

    attribute :active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :occurred_at, :utc_datetime_usec do
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
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_device_source_ref, [:device_uid, :source, :source_ref]
  end
end
