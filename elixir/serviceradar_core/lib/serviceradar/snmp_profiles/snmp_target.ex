defmodule ServiceRadar.SNMPProfiles.SNMPTarget do
  @moduledoc """
  SNMP target (network device) configuration within a profile.

  An SNMPTarget represents a specific network device to poll via SNMP. Each target
  belongs to an SNMPProfile and defines connection details, authentication, and
  the list of OIDs to collect.

  ## Attributes

  - `name`: Human-readable target name
  - `host`: Hostname or IP address
  - `port`: SNMP port (default 161)
  - `version`: SNMP protocol version (v1, v2c, v3)
  - `community`: Community string for SNMPv1/v2c
  - `username`: Username for SNMPv3
  - `security_level`: SNMPv3 security level
  - `auth_protocol`: SNMPv3 authentication protocol
  - `auth_password_encrypted`: Encrypted SNMPv3 auth password
  - `priv_protocol`: SNMPv3 privacy protocol
  - `priv_password_encrypted`: Encrypted SNMPv3 privacy password

  ## Authentication

  For SNMPv1/v2c, only the community string is needed.

  For SNMPv3, configure:
  - Security level: noAuthNoPriv, authNoPriv, authPriv
  - Auth protocol: MD5, SHA, SHA-224, SHA-256, SHA-384, SHA-512
  - Priv protocol: DES, AES, AES-192, AES-256

  Passwords are encrypted at rest using Cloak.

  ## Usage

      SNMPTarget
      |> Ash.Changeset.for_create(:create, %{
        name: "Core Router 1",
        host: "192.168.1.1",
        port: 161,
        version: :v2c,
        community: "public"
      })
      |> Ash.Changeset.manage_relationship(:snmp_profile, profile, type: :append)
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SNMPProfiles,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "snmp_targets"
    repo ServiceRadar.Repo

    references do
      reference :snmp_profile, on_delete: :delete
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :host,
        :port,
        :version,
        :username,
        :security_level,
        :auth_protocol,
        :priv_protocol
      ]

      argument :snmp_profile_id, :uuid, allow_nil?: false
      # All credentials are passed as arguments and encrypted before storage
      argument :community, :string, allow_nil?: true, sensitive?: true
      argument :auth_password, :string, allow_nil?: true, sensitive?: true
      argument :priv_password, :string, allow_nil?: true, sensitive?: true

      change manage_relationship(:snmp_profile_id, :snmp_profile, type: :append)
      change ServiceRadar.SNMPProfiles.Changes.EncryptCredentials
    end

    update :update do
      accept [
        :name,
        :host,
        :port,
        :version,
        :username,
        :security_level,
        :auth_protocol,
        :priv_protocol
      ]

      # All credentials are passed as arguments and encrypted before storage
      argument :community, :string, allow_nil?: true, sensitive?: true
      argument :auth_password, :string, allow_nil?: true, sensitive?: true
      argument :priv_password, :string, allow_nil?: true, sensitive?: true

      require_atomic? false
      change ServiceRadar.SNMPProfiles.Changes.EncryptCredentials
    end
  end

  policies do
    # Super admins and system actors bypass all checks
    bypass always() do
    end

    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Admins can create, update, and delete
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Everyone can read
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable target name"
    end

    attribute :host, :string do
      allow_nil? false
      public? true
      description "Hostname or IP address"
    end

    attribute :port, :integer do
      allow_nil? false
      default 161
      public? true
      description "SNMP port"
    end

    attribute :version, :atom do
      allow_nil? false
      default :v2c
      public? true
      constraints one_of: [:v1, :v2c, :v3]
      description "SNMP protocol version"
    end

    # SNMPv1/v2c authentication (encrypted at rest)
    attribute :community_encrypted, :binary do
      allow_nil? true
      public? false
      description "Encrypted community string for SNMPv1/v2c"
    end

    # SNMPv3 authentication
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
    belongs_to :snmp_profile, ServiceRadar.SNMPProfiles.SNMPProfile do
      allow_nil? false
    end

    has_many :oid_configs, ServiceRadar.SNMPProfiles.SNMPOIDConfig do
      destination_attribute :snmp_target_id
    end
  end

  identities do
    identity :unique_name_per_profile, [:snmp_profile_id, :name]
  end
end
