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
  - `enabled`: Whether this profile is available for use
  - `target_query`: SRQL query for device targeting (e.g., "in:devices tags.role:database")
  - `priority`: Priority for resolution order (higher = evaluated first)

  ## Device Targeting

  Profiles can target specific devices using SRQL queries. When resolving which
  profile to use for a device, profiles are evaluated in priority order (highest first).
  The first profile whose `target_query` matches the device is used. If no profile
  matches, sysmon is disabled for that device.

  Example queries:
  - `in:devices tags.role:database` - Match devices with role=database tag
  - `in:devices hostname:prod-*` - Match devices with hostname prefix "prod-"
  - `in:devices type:Server` - Match devices of type Server

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
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sysmon_profiles"
    repo ServiceRadar.Repo
    schema "platform"
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

    read :list_targeting_profiles do
      description """
      List profiles with SRQL targeting, ordered by priority (highest first).
      Used by the compiler to find which profile matches a device.
      """

      filter expr(enabled == true and not is_nil(target_query) and target_query != "")

      prepare fn query, _context ->
        Ash.Query.sort(query, priority: :desc)
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    admin_action_type([:create, :update, :destroy])
    read_viewer_plus()
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
    identity :unique_name, [:name]
  end
end
