defmodule ServiceRadar.DuskProfiles.DuskProfile do
  @moduledoc """
  Admin-managed profiles for Dusk blockchain node monitoring configuration.

  DuskProfile defines reusable configurations for the embedded dusk monitoring
  service in agents. Profiles control which Dusk node to monitor, connection
  timeout settings, and security configuration.

  ## Attributes

  - `name`: Human-readable profile name
  - `description`: Optional description of the profile's purpose
  - `node_address`: WebSocket address of the Dusk node to monitor (e.g., "localhost:8080")
  - `timeout`: Connection and operation timeout (e.g., "5m", "30s")
  - `is_default`: Whether this is the default profile for the instance
  - `enabled`: Whether this profile is available for use
  - `target_query`: SRQL query for device targeting (e.g., "in:devices tags.role:dusk-node")
  - `priority`: Priority for resolution order (higher = evaluated first)

  ## Device Targeting

  Profiles can target specific devices using SRQL queries. When resolving which
  profile to use for a device, profiles are evaluated in priority order (highest first).
  The first profile whose `target_query` matches the device is used.

  Example queries:
  - `in:devices tags.role:dusk-node` - Match devices with role=dusk-node tag
  - `in:devices hostname:dusk-*` - Match devices with hostname prefix "dusk-"

  ## Default Profile

  Each instance can have a default profile (is_default: true). When no targeting
  profile matches a device, the default profile is used. If no profile exists,
  dusk monitoring is disabled.

  ## Usage

      # Create a profile for dusk nodes
      DuskProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Production Dusk Node",
        node_address: "localhost:8080",
        timeout: "5m",
        target_query: "in:devices tags.role:dusk-node",
        priority: 10
      })
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.DuskProfiles,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "dusk_profiles"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :description,
        :node_address,
        :timeout,
        :is_default,
        :enabled,
        :target_query,
        :priority
      ]

      change ServiceRadar.DuskProfiles.Changes.ValidateSrqlQuery
    end

    update :update do
      accept [
        :name,
        :description,
        :node_address,
        :timeout,
        :enabled,
        :target_query,
        :priority
      ]

      require_atomic? false
      change ServiceRadar.DuskProfiles.Changes.ValidateSrqlQuery

      # Note: is_default cannot be changed via update
      # Use set_as_default action instead
    end

    update :set_as_default do
      description "Set this profile as the default for the instance"
      accept []
      require_atomic? false

      change ServiceRadar.DuskProfiles.Changes.SetAsDefault
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
      description """
      List profiles with SRQL targeting, ordered by priority (highest first).
      Used by the compiler to find which profile matches a device.
      """

      filter expr(enabled == true and is_default == false and not is_nil(target_query))

      prepare fn query, _context ->
        Ash.Query.sort(query, priority: :desc)
      end
    end
  end

  policies do
    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Admins can manage profiles
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Prevent deletion of default profile
    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
      forbid_if expr(is_default == true)
    end

    # Non-admin users can read profiles
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable profile name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Description of the profile's purpose"
    end

    attribute :node_address, :string do
      allow_nil? false
      public? true
      description "WebSocket address of the Dusk node (e.g., 'localhost:8080')"
    end

    attribute :timeout, :string do
      allow_nil? false
      public? true
      default "5m"
      description "Connection and operation timeout as duration string (e.g., '5m', '30s')"
    end

    attribute :is_default, :boolean do
      allow_nil? false
      public? true
      default false
      description "Whether this is the default profile for this deployment"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether this profile is available for use"
    end

    attribute :target_query, :string do
      allow_nil? true
      public? true
      description "SRQL query for device targeting (e.g., 'in:devices tags.role:dusk-node')"
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 0
      description "Priority for profile resolution (higher = evaluated first)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
