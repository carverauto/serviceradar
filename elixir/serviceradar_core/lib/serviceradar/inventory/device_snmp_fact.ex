defmodule ServiceRadar.Inventory.DeviceSNMPFact do
  @moduledoc """
  The current value of one polled SNMP OID, attached to the device it came from.

  This exists because `timeseries_metrics.value` is a non-nullable float while
  `string` is a legal SNMP data type. A software version, a node role, a service
  name - the values that are *facts about a device* rather than a series to
  graph - can be collected successfully today and then have nowhere to land.

  The split is by data shape, not by source: numeric OIDs keep going to
  `timeseries_metrics` exactly as before, and this is the current-state surface
  beside it. A row is replaced in place on each poll rather than appended, so
  this is a snapshot and never a history.

  `oid_index` is the walk row's index, and an empty string for a scalar get. It
  is not nullable: NULL does not compare equal to NULL in a unique index, so a
  nullable column would let the same scalar reading insert repeatedly instead of
  upserting.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fields [
    :device_uid,
    :oid,
    :oid_name,
    :oid_index,
    :value,
    :data_type,
    :plugin_package_id,
    :snmp_profile_id,
    :collected_at
  ]

  postgres do
    table "device_snmp_facts"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_uid]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields

      upsert? true
      upsert_identity :unique_reading

      upsert_fields [
        :oid_name,
        :value,
        :data_type,
        :snmp_profile_id,
        :plugin_package_id,
        :collected_at
      ]
    end

    update :update do
      accept @fields -- [:device_uid, :oid, :oid_index]
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [oid_name: :asc, oid_index: :asc])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :oid, :string do
      allow_nil? false
      public? true
    end

    attribute :oid_name, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    # Required explicitly rather than defaulted, because it is part of the
    # upsert identity: a caller who omitted it would collapse every row of a
    # walk onto one scalar reading instead of erroring. A writer always knows
    # whether it is storing a get or a walk row, so there is no burden in
    # saying so.
    attribute :oid_index, :string do
      allow_nil? false
      public? true

      # allow_empty? is false by default for Ash strings, which casts "" to nil
      # and then fails allow_nil? - so a scalar get, whose index IS the empty
      # string, could never be written.
      constraints allow_empty?: true, trim?: false, max_length: 128

      description "Walk row index; empty string for a scalar get"
    end

    # Text, not float. Holding a version string or a node role is the whole
    # point of this table.
    attribute :value, :string do
      public? true
    end

    attribute :data_type, :string do
      allow_nil? false
      public? true
      constraints max_length: 32
    end

    attribute :plugin_package_id, :uuid do
      public? true
      description "Plugin package that declared this OID, when any"
    end

    attribute :snmp_profile_id, :uuid do
      public? true
      description "Profile that collected this reading"
    end

    attribute :collected_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      define_attribute? false
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_reading, [:device_uid, :oid, :oid_index]
  end
end
