defmodule ServiceRadar.SNMPProfiles.SNMPProfile do
  @moduledoc """
  Admin-managed profiles for SNMP monitoring configuration.

  SNMPProfile defines reusable configurations for SNMP monitoring. Each profile
  contains a list of SNMP targets (network devices) to poll and uses SRQL
  queries to determine which agents receive the profile.

  ## Attributes

  - `name`: Human-readable profile name
  - `description`: Optional description of the profile's purpose
  - `poll_interval`: Default polling interval for targets (e.g., 60 seconds)
  - `timeout`: SNMP request timeout (e.g., 5 seconds)
  - `retries`: Number of retry attempts on failure
  - `is_default`: Whether this is the default profile for the instance
  - `enabled`: Whether this profile is available for use
  - `target_query`: SRQL query for device targeting
  - `priority`: Priority for resolution order (higher = evaluated first)
  - `version`: SNMP protocol version (v1, v2c, v3)
  - `community`: SNMP community string (v1/v2c, encrypted)
  - `username`: SNMPv3 username
  - `security_level`: SNMPv3 security level
  - `auth_protocol`: SNMPv3 auth protocol
  - `auth_password`: SNMPv3 auth password (encrypted)
  - `priv_protocol`: SNMPv3 privacy protocol
  - `priv_password`: SNMPv3 privacy password (encrypted)

  ## Device Targeting

  Profiles target agents using SRQL queries. The agents that match the query
  will poll the SNMP targets defined in this profile.

  Example queries:
  - `in:devices tags.role:network-monitor` - Match network monitoring agents
  - `in:devices location:datacenter-1` - Match agents in a specific location
  - `in:interfaces type:ethernet` - Match agents with ethernet interfaces

  ## Default Profile

  Each instance has exactly one default profile (is_default: true). When no targeting
  profile matches a device, the default profile is used (if SNMP monitoring is needed).

  ## Usage

      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Core Network Monitoring",
        description: "Monitor core routers and switches",
        poll_interval: 60,
        timeout: 5,
        retries: 3,
        target_query: "in:devices tags.role:network-monitor",
        priority: 10
      })
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SNMPProfiles,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "snmp_profiles"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :description,
        :poll_interval,
        :timeout,
        :retries,
        :is_default,
        :enabled,
        :target_query,
        :priority,
        :version,
        :username,
        :security_level,
        :auth_protocol,
        :priv_protocol,
        :oid_template_ids
      ]

      argument :community, :string, allow_nil?: true, sensitive?: true
      argument :auth_password, :string, allow_nil?: true, sensitive?: true
      argument :priv_password, :string, allow_nil?: true, sensitive?: true

      change ServiceRadar.SNMPProfiles.Changes.ValidateSrqlQuery
      change ServiceRadar.SNMPProfiles.Changes.EncryptCredentials
    end

    update :update do
      accept [
        :name,
        :description,
        :poll_interval,
        :timeout,
        :retries,
        :enabled,
        :target_query,
        :priority,
        :version,
        :username,
        :security_level,
        :auth_protocol,
        :priv_protocol,
        :oid_template_ids
      ]

      argument :community, :string, allow_nil?: true, sensitive?: true
      argument :auth_password, :string, allow_nil?: true, sensitive?: true
      argument :priv_password, :string, allow_nil?: true, sensitive?: true

      require_atomic? false
      change ServiceRadar.SNMPProfiles.Changes.ValidateSrqlQuery
      change ServiceRadar.SNMPProfiles.Changes.EncryptCredentials
    end

    update :set_as_default do
      description "Set this profile as the default for the instance"
      accept []
      require_atomic? false

      change ServiceRadar.SNMPProfiles.Changes.SetAsDefault
    end

    update :unset_default do
      description "Remove this profile as the default (internal use only)"
      accept []
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :is_default, false)
      end
    end

    read :list_available do
      description "List profiles available for use"
      filter expr(enabled == true)
    end

    read :by_name do
      description "Get a specific profile by name"
      argument :name, :string, allow_nil?: false
      get? true
      filter expr(name == ^arg(:name))
    end

    read :get_default do
      description "Get the default profile for the instance"
      get? true
      filter expr(is_default == true)
    end

    read :list_targeting_profiles do
      description "List profiles with SRQL targeting, ordered by priority"
      filter expr(enabled == true and is_default == false and not is_nil(target_query))

      prepare fn query, _context ->
        Ash.Query.sort(query, priority: :desc)
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    admin_action_type(:create)
    admin_action_type(:update)
    read_all()

    # Cannot delete default profiles
    policy action_type(:destroy) do
      forbid_if expr(is_default == true)
      authorize_if is_admin()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable profile name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Optional description of the profile's purpose"
    end

    # Polling configuration
    attribute :poll_interval, :integer do
      allow_nil? false
      default 60
      public? true
      description "Default polling interval in seconds"
    end

    attribute :timeout, :integer do
      allow_nil? false
      default 5
      public? true
      description "SNMP request timeout in seconds"
    end

    attribute :retries, :integer do
      allow_nil? false
      default 3
      public? true
      description "Number of retry attempts on failure"
    end

    # Profile state
    attribute :is_default, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether this is the default profile for the instance"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether this profile is available for use"
    end

    # Device targeting
    attribute :target_query, :string do
      allow_nil? true
      public? true
      description "SRQL query for device targeting (e.g., 'in:devices tags.role:network-monitor')"
    end

    attribute :priority, :integer do
      allow_nil? false
      default 0
      public? true
      description "Priority for resolution order (higher = evaluated first)"
    end

    # OID template selection
    attribute :oid_template_ids, {:array, :uuid} do
      allow_nil? true
      default []
      public? true
      description "List of OID template IDs to apply when polling devices matched by this profile"
    end

    # SNMP credentials (profile-scoped, encrypted at rest)
    attribute :version, :atom do
      allow_nil? false
      default :v2c
      public? true
      constraints one_of: [:v1, :v2c, :v3]
      description "SNMP protocol version for this profile"
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
    has_many :targets, ServiceRadar.SNMPProfiles.SNMPTarget do
      destination_attribute :snmp_profile_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
