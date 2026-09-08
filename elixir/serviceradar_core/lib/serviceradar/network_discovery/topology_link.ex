defmodule ServiceRadar.NetworkDiscovery.TopologyLink do
  @moduledoc """
  Stores mapper-discovered topology links for network graph projection.
  """

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mapper_topology_links"
    repo ServiceRadar.Repo
    schema "platform"

    # Bind the logical-key identity to the hand-written unique index created in
    # priv/repo/migrations/..._add_mapper_topology_links_logical_key_uidx.exs. The
    # index is plain-column (the key columns are NOT NULL DEFAULT ''/0), so Ash's
    # ON CONFLICT (cols) inference matches it exactly.
    identity_index_names logical_key: "mapper_topology_links_logical_key_uidx"
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :timestamp,
        :agent_id,
        :gateway_id,
        :partition,
        :protocol,
        :local_device_ip,
        :local_device_id,
        :local_if_index,
        :local_if_name,
        :neighbor_device_id,
        :neighbor_chassis_id,
        :neighbor_port_id,
        :neighbor_port_descr,
        :neighbor_system_name,
        :neighbor_mgmt_addr,
        :metadata,
        :created_at
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    operator_action_type(:create)
    read_all()
  end

  attributes do
    uuid_primary_key :id

    attribute :timestamp, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :agent_id, :string do
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :partition, :string do
      default "default"
      public? true
    end

    # Logical-key columns are NOT NULL with empty/zero defaults so the unique index
    # backing the :logical_key identity can be plain-column (no COALESCE), letting
    # Ash's upsert ON CONFLICT inference target it directly.
    #
    # The string columns need `allow_empty?: true, trim?: false`: Ash's :string
    # type defaults to `allow_empty?: false, trim?: true`, which casts a provided
    # "" back to nil and then fails the allow_nil? false validation. The ingestor
    # deliberately writes "" sentinels for logical-key fields that are legitimately
    # absent (SNMP-L2 ARP+FDB attachments, UniFi wireless clients, and
    # wireguard-derived links carry no neighbor_port_id), so the sentinel must
    # survive casting.
    attribute :protocol, :string do
      allow_nil? false
      default ""
      constraints allow_empty?: true, trim?: false
      public? true
    end

    attribute :local_device_ip, :string do
      public? true
    end

    attribute :local_device_id, :string do
      allow_nil? false
      default ""
      constraints allow_empty?: true, trim?: false
      public? true
    end

    attribute :local_if_index, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :local_if_name, :string do
      public? true
    end

    attribute :neighbor_device_id, :string do
      allow_nil? false
      default ""
      constraints allow_empty?: true, trim?: false
      public? true
    end

    attribute :neighbor_chassis_id, :string do
      allow_nil? false
      default ""
      constraints allow_empty?: true, trim?: false
      public? true
    end

    attribute :neighbor_port_id, :string do
      allow_nil? false
      default ""
      constraints allow_empty?: true, trim?: false
      public? true
    end

    attribute :neighbor_port_descr, :string do
      public? true
    end

    attribute :neighbor_system_name, :string do
      public? true
    end

    attribute :neighbor_mgmt_addr, :string do
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    attribute :created_at, :utc_datetime do
      public? true
    end
  end

  identities do
    # Logical key for a topology edge. Backed by the plain-column unique index
    # mapper_topology_links_logical_key_uidx (see postgres.identity_index_names).
    # Used by the mapper ingestor's upsert so the every-5-minute re-insert of the
    # whole topology updates-in-place instead of appending duplicate rows.
    identity :logical_key, [
      :local_device_id,
      :neighbor_device_id,
      :local_if_index,
      :neighbor_port_id,
      :protocol,
      :neighbor_chassis_id
    ]
  end
end
