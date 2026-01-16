defmodule ServiceRadar.SweepJobs.SweepProfile do
  @moduledoc """
  Admin-managed scanner profiles for network sweeps.

  SweepProfile defines reusable scan configurations that can be inherited by
  SweepGroups. Profiles are typically managed by administrators and define
  the technical parameters of how scans are performed.

  ## Attributes

  - `name`: Human-readable profile name
  - `description`: Optional description of the profile's purpose
  - `ports`: List of TCP ports to scan (e.g., [22, 80, 443, 8080])
  - `sweep_modes`: Scan modes to use ("icmp", "tcp", "arp")
  - `concurrency`: Max concurrent host scans
  - `timeout`: Per-host timeout (e.g., "3s", "5s")
  - `icmp_settings`: ICMP-specific settings (count, interval)
  - `tcp_settings`: TCP-specific settings (syn_only, connect_timeout)
  - `admin_only`: If true, only admins can use this profile

  ## Usage

      # Create a profile for web servers
      SweepProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Web Server Scan",
        ports: [80, 443, 8080, 8443],
        sweep_modes: ["tcp", "icmp"]
      })
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.AgentConfig.ConfigInvalidationNotifier]

  postgres do
    table "sweep_profiles"
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
        :ports,
        :sweep_modes,
        :concurrency,
        :timeout,
        :icmp_settings,
        :tcp_settings,
        :admin_only,
        :enabled
      ]

    end

    update :update do
      accept [
        :name,
        :description,
        :ports,
        :sweep_modes,
        :concurrency,
        :timeout,
        :icmp_settings,
        :tcp_settings,
        :admin_only,
        :enabled
      ]
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

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Non-admin users can read non-admin-only profiles
    policy action_type(:read) do
      authorize_if expr(admin_only == false)
      authorize_if actor_attribute_equals(:role, :admin)
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

    attribute :ports, {:array, :integer} do
      allow_nil? false
      public? true
      default []
      description "List of TCP ports to scan"
    end

    attribute :sweep_modes, {:array, :string} do
      allow_nil? false
      public? true
      default ["icmp", "tcp"]
      description "Scan modes: icmp, tcp, arp"
    end

    attribute :concurrency, :integer do
      allow_nil? false
      public? true
      default 50
      description "Maximum concurrent host scans"
    end

    attribute :timeout, :string do
      allow_nil? false
      public? true
      default "3s"
      description "Per-host scan timeout"
    end

    attribute :icmp_settings, :map do
      allow_nil? false
      public? true
      default %{}
      description "ICMP-specific settings (count, interval)"
    end

    attribute :tcp_settings, :map do
      allow_nil? false
      public? true
      default %{}
      description "TCP-specific settings (syn_only, connect_timeout)"
    end

    attribute :admin_only, :boolean do
      allow_nil? false
      public? true
      default false
      description "If true, only admins can use this profile"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether this profile is available for use"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :sweep_groups, ServiceRadar.SweepJobs.SweepGroup do
      destination_attribute :profile_id
    end
  end

  calculations do
    calculate :usage_count, :integer, expr(count(sweep_groups))
  end

  identities do
    identity :unique_name_per_tenant, [:tenant_id, :name]
  end
end
