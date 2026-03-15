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

  alias ServiceRadar.SNMPProfiles.Changes.EncryptCredentials
  alias ServiceRadar.SNMPProfiles.CredentialDsl

  require CredentialDsl

  @target_fields [
    :name,
    :host,
    :port,
    :version,
    :username,
    :security_level,
    :auth_protocol,
    :priv_protocol
  ]

  postgres do
    table "snmp_targets"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :snmp_profile, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @target_fields

      argument :snmp_profile_id, :uuid, allow_nil?: false
      # All credentials are passed as arguments and encrypted before storage
      CredentialDsl.credential_action_arguments()

      change manage_relationship(:snmp_profile_id, :snmp_profile, type: :append)
      change EncryptCredentials
    end

    update :update do
      accept @target_fields

      # All credentials are passed as arguments and encrypted before storage
      CredentialDsl.credential_action_arguments()

      require_atomic? false
      change EncryptCredentials
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    admin_action_type([:create, :update, :destroy])
    read_all()
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

    CredentialDsl.credential_attributes()

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
