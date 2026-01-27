defmodule ServiceRadar.Inventory.DeviceSNMPCredential do
  @moduledoc """
  Per-device SNMP credential override.

  When present, these credentials override any profile-scoped SNMP credentials
  for the device. Credentials are encrypted at rest.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_snmp_credentials"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_device, action: :by_device, args: [:device_id]
    define :upsert_for_device, action: :upsert, args: [:device_id]
  end

  actions do
    defaults [:read]

    destroy :destroy do
      change ServiceRadar.Inventory.Changes.InvalidateSnmpConfigs
    end

    create :create do
      accept [
        :device_id,
        :version,
        :username,
        :security_level,
        :auth_protocol,
        :priv_protocol
      ]

      argument :community, :string, allow_nil?: true, sensitive?: true
      argument :auth_password, :string, allow_nil?: true, sensitive?: true
      argument :priv_password, :string, allow_nil?: true, sensitive?: true

      change ServiceRadar.SNMPProfiles.Changes.EncryptCredentials
      change ServiceRadar.Inventory.Changes.InvalidateSnmpConfigs
    end

    update :update do
      accept [
        :version,
        :username,
        :security_level,
        :auth_protocol,
        :priv_protocol
      ]

      argument :community, :string, allow_nil?: true, sensitive?: true
      argument :auth_password, :string, allow_nil?: true, sensitive?: true
      argument :priv_password, :string, allow_nil?: true, sensitive?: true

      change ServiceRadar.SNMPProfiles.Changes.EncryptCredentials
      change ServiceRadar.Inventory.Changes.InvalidateSnmpConfigs
    end

    create :upsert do
      description "Create or update device SNMP credentials"
      upsert? true
      upsert_identity :unique_device

      argument :device_id, :string, allow_nil?: false

      accept [
        :version,
        :username,
        :security_level,
        :auth_protocol,
        :priv_protocol
      ]

      argument :community, :string, allow_nil?: true, sensitive?: true
      argument :auth_password, :string, allow_nil?: true, sensitive?: true
      argument :priv_password, :string, allow_nil?: true, sensitive?: true

      change set_attribute(:device_id, arg(:device_id))
      change ServiceRadar.SNMPProfiles.Changes.EncryptCredentials
      change ServiceRadar.Inventory.Changes.InvalidateSnmpConfigs
    end

    read :by_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
      get? true
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :device_id, :string do
      allow_nil? false
      public? true
      description "Device UID for this credential override"
    end

    attribute :version, :atom do
      allow_nil? false
      default :v2c
      public? true
      constraints one_of: [:v1, :v2c, :v3]
      description "SNMP protocol version"
    end

    attribute :community_encrypted, :binary do
      allow_nil? true
      public? false
      description "Encrypted community string for SNMPv1/v2c"
    end

    attribute :username, :string do
      allow_nil? true
      public? true
      description "Username for SNMPv3"
    end

    attribute :security_level, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:no_auth_no_priv, :auth_no_priv, :auth_priv]
      description "SNMPv3 security level"
    end

    attribute :auth_protocol, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:md5, :sha, :sha224, :sha256, :sha384, :sha512]
      description "SNMPv3 authentication protocol"
    end

    attribute :auth_password_encrypted, :binary do
      allow_nil? true
      public? false
      description "Encrypted SNMPv3 auth password"
    end

    attribute :priv_protocol, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:des, :aes, :aes192, :aes256, :aes192c, :aes256c]
      description "SNMPv3 privacy (encryption) protocol"
    end

    attribute :priv_password_encrypted, :binary do
      allow_nil? true
      public? false
      description "Encrypted SNMPv3 privacy password"
    end

    timestamps()
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_id
      destination_attribute :uid
      define_attribute? false
      allow_nil? false
      public? true
      description "Device this credential override applies to"
    end
  end

  identities do
    identity :unique_device, [:device_id]
  end
end
