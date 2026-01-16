defmodule ServiceRadar.SNMPProfiles.SNMPOIDTemplate do
  @moduledoc """
  Reusable OID template definitions.

  SNMPOIDTemplate provides predefined sets of OIDs for common monitoring scenarios.
  Templates are organized by vendor and can be either built-in (shipped with the
  product) or custom (created by tenant admins).

  ## Attributes

  - `name`: Template name (e.g., "Interface Statistics")
  - `description`: Description of what the template monitors
  - `vendor`: Vendor category (standard, cisco, juniper, arista, custom)
  - `category`: Functional category (interface, cpu-memory, environment, bgp, etc.)
  - `oids`: List of OID configurations
  - `is_builtin`: Whether this is a built-in template (read-only)

  ## Vendor Categories

  - `standard`: MIB-II / RFC standard OIDs (work with most devices)
  - `cisco`: Cisco-specific OIDs
  - `juniper`: Juniper-specific OIDs
  - `arista`: Arista-specific OIDs
  - `custom`: User-created templates

  ## OID List Format

  The `oids` attribute is a list of maps with the following structure:

      [
        %{
          "oid" => ".1.3.6.1.2.1.2.2.1.10",
          "name" => "ifInOctets",
          "data_type" => "counter",
          "scale" => 1.0,
          "delta" => true
        },
        ...
      ]

  ## Usage

      # Create a custom template
      SNMPOIDTemplate
      |> Ash.Changeset.for_create(:create, %{
        name: "My Router Monitoring",
        description: "Custom OIDs for our router model",
        vendor: "custom",
        category: "interface",
        oids: [
          %{oid: ".1.3.6.1.4.1.9.2.1.56.0", name: "avgBusy1", data_type: "gauge"}
        ]
      })
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SNMPProfiles,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "snmp_oid_templates"
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
        :vendor,
        :category,
        :oids
      ]

      change fn changeset, _context ->
        # Custom templates are never builtin
        Ash.Changeset.force_change_attribute(changeset, :is_builtin, false)
      end
    end

    update :update do
      accept [
        :name,
        :description,
        :vendor,
        :category,
        :oids
      ]

      require_atomic? false

      # Cannot modify builtin templates
      validate fn changeset, _context ->
        if Ash.Changeset.get_data(changeset, :is_builtin) do
          {:error, "Cannot modify built-in templates"}
        else
          :ok
        end
      end
    end

    read :list_by_vendor do
      description "List templates filtered by vendor"
      argument :vendor, :string, allow_nil?: false
      filter expr(vendor == ^arg(:vendor))
    end

    read :list_custom do
      description "List custom (non-builtin) templates"
      filter expr(is_builtin == false)
    end

    read :list_builtin do
      description "List built-in templates"
      filter expr(is_builtin == true)
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

    # Admins can create custom templates
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Can only update/delete non-builtin templates
    policy action_type(:update) do
      forbid_if expr(is_builtin == true)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:destroy) do
      forbid_if expr(is_builtin == true)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Everyone can read
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? true
      public? true
      description "Tenant ID (nil for built-in templates)"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Template name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Description of what the template monitors"
    end

    attribute :vendor, :string do
      allow_nil? false
      public? true
      description "Vendor category: standard, cisco, juniper, arista, custom"
    end

    attribute :category, :string do
      allow_nil? true
      public? true
      description "Functional category: interface, cpu-memory, environment, bgp, etc."
    end

    attribute :oids, {:array, :map} do
      allow_nil? false
      default []
      public? true
      description "List of OID configurations"
    end

    attribute :is_builtin, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether this is a built-in template (read-only)"
    end

    timestamps()
  end

  identities do
    identity :unique_name_per_vendor_tenant, [:tenant_id, :vendor, :name]
  end
end
