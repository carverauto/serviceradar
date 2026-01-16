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
  - `is_default`: Whether this is the default profile for the tenant
  - `enabled`: Whether this profile is available for use
  - `target_query`: SRQL query for device targeting
  - `priority`: Priority for resolution order (higher = evaluated first)

  ## Device Targeting

  Profiles target agents using SRQL queries. The agents that match the query
  will poll the SNMP targets defined in this profile.

  Example queries:
  - `in:devices tags.role:network-monitor` - Match network monitoring agents
  - `in:devices location:datacenter-1` - Match agents in a specific location
  - `in:interfaces type:ethernet` - Match agents with ethernet interfaces

  ## Default Profile

  Each tenant has exactly one default profile (is_default: true). When no targeting
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
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.AgentConfig.ConfigInvalidationNotifier]

  postgres do
    table "snmp_profiles"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
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
        :priority
      ]

      change ServiceRadar.SNMPProfiles.Changes.ValidateSrqlQuery
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
        :priority
      ]

      require_atomic? false
      change ServiceRadar.SNMPProfiles.Changes.ValidateSrqlQuery
    end

    update :set_as_default do
      description "Set this profile as the default for the tenant"
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
      description "Get the default profile for the tenant"
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
    # Super admins and system actors bypass all checks
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Admins can create and update
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Everyone can read
    policy action_type(:read) do
      authorize_if always()
    end

    # Cannot delete default profiles
    policy action_type(:destroy) do
      forbid_if expr(is_default == true)
      authorize_if actor_attribute_equals(:role, :admin)
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
      description "Whether this is the default profile for the tenant"
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
