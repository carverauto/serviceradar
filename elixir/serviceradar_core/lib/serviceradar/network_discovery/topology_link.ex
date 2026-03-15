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

    attribute :protocol, :string do
      public? true
    end

    attribute :local_device_ip, :string do
      public? true
    end

    attribute :local_device_id, :string do
      public? true
    end

    attribute :local_if_index, :integer do
      public? true
    end

    attribute :local_if_name, :string do
      public? true
    end

    attribute :neighbor_device_id, :string do
      public? true
    end

    attribute :neighbor_chassis_id, :string do
      public? true
    end

    attribute :neighbor_port_id, :string do
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
end
