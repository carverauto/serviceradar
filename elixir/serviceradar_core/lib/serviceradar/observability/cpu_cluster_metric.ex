defmodule ServiceRadar.Observability.CpuClusterMetric do
  @moduledoc """
  CPU cluster metric resource.

  Maps to the `cpu_cluster_metrics` TimescaleDB hypertable. This table is managed by raw SQL
  migrations that match the Go schema exactly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "cpu_cluster_metrics"
    repo ServiceRadar.Repo
    migrate? false
  end

  json_api do
    type "cpu_cluster_metric"

    routes do
      base "/cpu_cluster_metrics"

      index :read
    end
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

    read :recent do
      description "Metrics from the last 24 hours"
      filter expr(timestamp > ago(24, :hour))
    end

    create :create do
      accept [
        :timestamp,
        :gateway_id,
        :agent_id,
        :host_id,
        :cluster,
        :frequency_hz,
        :device_id,
        :partition,
        :created_at
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
    attribute :timestamp, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the metric was recorded"
    end

    attribute :gateway_id, :string do
      allow_nil? false
      public? true
      description "Gateway that collected this metric"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent ID"
    end

    attribute :host_id, :string do
      public? true
      description "Host identifier"
    end

    attribute :cluster, :string do
      public? true
      description "Cluster name"
    end

    attribute :frequency_hz, :float do
      public? true
      description "Cluster frequency in Hz"
    end

    attribute :device_id, :string do
      public? true
      description "Device identifier"
    end

    attribute :partition, :string do
      public? true
      description "Partition"
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the record was created"
    end
  end
end
