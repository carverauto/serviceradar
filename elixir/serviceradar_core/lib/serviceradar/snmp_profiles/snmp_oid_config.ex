defmodule ServiceRadar.SNMPProfiles.SNMPOIDConfig do
  @moduledoc """
  OID configuration for an SNMP target.

  An SNMPOIDConfig represents a single OID to poll from an SNMP target. Each
  OID config defines what data to collect and how to process it.

  ## Attributes

  - `oid`: The OID string (e.g., ".1.3.6.1.2.1.1.1.0")
  - `name`: Human-readable name (e.g., "sysDescr")
  - `data_type`: Expected data type (counter, gauge, boolean, bytes, string, float, timeticks)
  - `scale`: Scale factor to apply to the value (default 1.0)
  - `delta`: Whether to calculate rate of change between samples

  ## Data Types

  - `counter`: Monotonically increasing counter (e.g., ifInOctets)
  - `gauge`: Current value that can go up or down (e.g., CPU usage)
  - `boolean`: True/false value
  - `bytes`: Byte count
  - `string`: Text value
  - `float`: Floating point value
  - `timeticks`: Time value in hundredths of a second

  ## Delta Calculation

  For counter types, enable `delta: true` to report the rate of change between
  samples rather than the absolute value. This is useful for bandwidth metrics
  (bytes/sec) rather than total bytes.

  ## Usage

      SNMPOIDConfig
      |> Ash.Changeset.for_create(:create, %{
        oid: ".1.3.6.1.2.1.2.2.1.10",
        name: "ifInOctets",
        data_type: :counter,
        delta: true
      })
      |> Ash.Changeset.manage_relationship(:snmp_target, target, type: :append)
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SNMPProfiles,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "snmp_oid_configs"
    repo ServiceRadar.Repo

    references do
      reference :snmp_target, on_delete: :delete
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :oid,
        :name,
        :data_type,
        :scale,
        :delta
      ]

      argument :snmp_target_id, :uuid, allow_nil?: false

      change manage_relationship(:snmp_target_id, :snmp_target, type: :append)
    end

    update :update do
      accept [
        :oid,
        :name,
        :data_type,
        :scale,
        :delta
      ]
    end

    create :create_bulk do
      description "Create multiple OID configs at once"
      accept [:oid, :name, :data_type, :scale, :delta]
      argument :snmp_target_id, :uuid, allow_nil?: false

      change manage_relationship(:snmp_target_id, :snmp_target, type: :append)
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

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :oid, :string do
      allow_nil? false
      public? true
      description "OID string (e.g., '.1.3.6.1.2.1.1.1.0')"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable name (e.g., 'sysDescr')"
    end

    attribute :data_type, :atom do
      allow_nil? false
      default :gauge
      public? true
      constraints one_of: [:counter, :gauge, :boolean, :bytes, :string, :float, :timeticks]
      description "Expected data type"
    end

    attribute :scale, :float do
      allow_nil? false
      default 1.0
      public? true
      description "Scale factor to apply to the value"
    end

    attribute :delta, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether to calculate rate of change between samples"
    end

    timestamps()
  end

  relationships do
    belongs_to :snmp_target, ServiceRadar.SNMPProfiles.SNMPTarget do
      allow_nil? false
    end
  end

  identities do
    identity :unique_oid_per_target, [:snmp_target_id, :oid]
  end
end
