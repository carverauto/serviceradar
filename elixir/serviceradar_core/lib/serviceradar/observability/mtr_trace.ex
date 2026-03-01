defmodule ServiceRadar.Observability.MtrTrace do
  @moduledoc """
  MTR trace execution resource.

  Maps to the `mtr_traces` TimescaleDB hypertable. Each row represents a single
  MTR trace run — target, protocol, reachability status, and path metadata.
  Schema is managed by raw SQL migration.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mtr_traces"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  resource do
    require_primary_key? false
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :by_target_ip do
      argument :target_ip, :string, allow_nil?: false
      filter expr(target_ip == ^arg(:target_ip))
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id))
    end

    read :recent do
      description "Traces from the last 24 hours"
      filter expr(time > ago(24, :hour))
    end

    create :create do
      accept [
        :id,
        :time,
        :agent_id,
        :gateway_id,
        :check_id,
        :check_name,
        :device_id,
        :target,
        :target_ip,
        :target_reached,
        :total_hops,
        :protocol,
        :ip_version,
        :packet_size,
        :partition,
        :error
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end
  end

  attributes do
    attribute :id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :time, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the trace was executed"
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :check_id, :string do
      public? true
    end

    attribute :check_name, :string do
      public? true
    end

    attribute :device_id, :string do
      public? true
    end

    attribute :target, :string do
      allow_nil? false
      public? true
      description "Target hostname or IP"
    end

    attribute :target_ip, :string do
      allow_nil? false
      public? true
      description "Resolved target IP address"
    end

    attribute :target_reached, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :total_hops, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :protocol, :string do
      allow_nil? false
      default "icmp"
      public? true
    end

    attribute :ip_version, :integer do
      allow_nil? false
      default 4
      public? true
    end

    attribute :packet_size, :integer do
      public? true
    end

    attribute :partition, :string do
      public? true
    end

    attribute :error, :string do
      public? true
    end

    attribute :created_at, :utc_datetime_usec do
      public? true
    end
  end
end
