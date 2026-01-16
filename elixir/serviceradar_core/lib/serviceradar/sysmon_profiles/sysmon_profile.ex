defmodule ServiceRadar.SysmonProfiles.SysmonProfile do
  @moduledoc """
  Admin-managed profiles for system monitoring configuration.

  SysmonProfile defines reusable configurations for the embedded sysmon collector
  in agents. Profiles control what metrics are collected, at what interval, and
  alert thresholds.

  ## Attributes

  - `name`: Human-readable profile name
  - `description`: Optional description of the profile's purpose
  - `sample_interval`: Collection interval (e.g., "10s", "1m", "500ms")
  - `collect_cpu`: Enable CPU metrics collection
  - `collect_memory`: Enable memory metrics collection
  - `collect_disk`: Enable disk metrics collection
  - `collect_network`: Enable network interface metrics collection
  - `collect_processes`: Enable process metrics collection (can be resource-intensive)
  - `disk_paths`: Specific paths to monitor (empty means all mounted filesystems)
  - `disk_exclude_paths`: Paths to omit from disk metrics collection
  - `thresholds`: Alert thresholds as key-value pairs
  - `is_default`: Whether this is the default profile for the tenant
  - `enabled`: Whether this profile is available for use
  - `target_query`: SRQL query for device targeting (e.g., "in:devices tags.role:database")
  - `priority`: Priority for resolution order (higher = evaluated first)

  ## Device Targeting

  Profiles can target specific devices using SRQL queries. When resolving which
  profile to use for a device, profiles are evaluated in priority order (highest first).
  The first profile whose `target_query` matches the device is used.

  Example queries:
  - `in:devices tags.role:database` - Match devices with role=database tag
  - `in:devices hostname:prod-*` - Match devices with hostname prefix "prod-"
  - `in:devices type:Server` - Match devices of type Server

  ## Default Profile

  Each tenant has exactly one default profile (is_default: true). When no targeting
  profile matches a device, the default profile is used. The default profile
  cannot be deleted and has no `target_query` (applies to all unmatched devices).

  ## Usage

      # Create a profile for database servers
      SysmonProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Database Servers",
        sample_interval: "5s",
        collect_cpu: true,
        collect_memory: true,
        collect_disk: true,
        collect_processes: true,
        target_query: "in:devices tags.role:database",
        priority: 10,
        thresholds: %{
          "cpu_warning" => "70",
          "cpu_critical" => "90",
          "memory_warning" => "80",
          "memory_critical" => "95"
        }
      })
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SysmonProfiles,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.AgentConfig.ConfigInvalidationNotifier]

  postgres do
    table "sysmon_profiles"
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
        :sample_interval,
        :collect_cpu,
        :collect_memory,
        :collect_disk,
        :collect_network,
        :collect_processes,
        :disk_paths,
        :disk_exclude_paths,
        :thresholds,
        :is_default,
        :enabled,
        :target_query,
        :priority
      ]

      change ServiceRadar.SysmonProfiles.Changes.ValidateSrqlQuery
    end

    update :update do
      accept [
        :name,
        :description,
        :sample_interval,
        :collect_cpu,
        :collect_memory,
        :collect_disk,
        :collect_network,
        :collect_processes,
        :disk_paths,
        :disk_exclude_paths,
        :thresholds,
        :enabled,
        :target_query,
        :priority
      ]

      require_atomic? false
      change ServiceRadar.SysmonProfiles.Changes.ValidateSrqlQuery

      # Note: is_default cannot be changed via update
      # Use set_as_default action instead
    end

    update :set_as_default do
      description "Set this profile as the default for the tenant"
      accept []
      require_atomic? false

      change ServiceRadar.SysmonProfiles.Changes.SetAsDefault
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
      description "Get the default profile for the tenant"
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
    # Super admins can do anything
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # System actors can perform all operations (tenant isolation via schema)
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

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this profile belongs to"
    end

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

    attribute :sample_interval, :string do
      allow_nil? false
      public? true
      default "10s"
      description "Collection interval as duration string (e.g., '10s', '1m', '500ms')"
    end

    attribute :collect_cpu, :boolean do
      allow_nil? false
      public? true
      default true
      description "Enable CPU metrics collection"
    end

    attribute :collect_memory, :boolean do
      allow_nil? false
      public? true
      default true
      description "Enable memory metrics collection"
    end

    attribute :collect_disk, :boolean do
      allow_nil? false
      public? true
      default true
      description "Enable disk metrics collection"
    end

    attribute :collect_network, :boolean do
      allow_nil? false
      public? true
      default false
      description "Enable network interface metrics collection"
    end

    attribute :collect_processes, :boolean do
      allow_nil? false
      public? true
      default false
      description "Enable process metrics collection (can be resource-intensive)"
    end

    attribute :disk_paths, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "Disk mount points to monitor (empty means all)"
    end

    attribute :disk_exclude_paths, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "Disk mount points to exclude"
    end

    attribute :thresholds, :map do
      allow_nil? false
      public? true
      default %{}
      description "Alert thresholds as key-value pairs (e.g., cpu_warning: '80')"
    end

    attribute :is_default, :boolean do
      allow_nil? false
      public? true
      default false
      description "Whether this is the default profile for the tenant"
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
      description "SRQL query for device targeting (e.g., 'in:devices tags.role:database')"
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

  # Note: SysmonProfileAssignment removed - use target_query for SRQL-based targeting

  identities do
    identity :unique_name_per_tenant, [:tenant_id, :name]
  end
end
