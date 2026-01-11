defmodule ServiceRadar.Observability.TimeseriesMetric do
  @moduledoc """
  Generic time-series metric resource.

  Maps to the `timeseries_metrics` TimescaleDB hypertable. This table is managed by raw SQL
  migrations that match the Go schema exactly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "timeseries_metrics"
    repo ServiceRadar.Repo
    # Don't generate migrations - table is managed by raw SQL migration
    # that creates TimescaleDB hypertable matching Go schema
    migrate? false
  end

  json_api do
    type "timeseries_metric"

    routes do
      base "/timeseries_metrics"

      index :read
    end
  end

  multitenancy do
    strategy :context
  end

  resource do
    # TimescaleDB hypertables don't have traditional primary keys
    require_primary_key? false
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :by_metric_name do
      argument :metric_name, :string, allow_nil?: false
      filter expr(metric_name == ^arg(:metric_name))
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
        :metric_name,
        :metric_type,
        :device_id,
        :value,
        :unit,
        :tags,
        :partition,
        :scale,
        :is_delta,
        :target_device_ip,
        :if_index,
        :metadata
      ]
    end
  end

  policies do
    # Reads are tenant-scoped by schema isolation
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end
  end

  # Note: This hypertable does not include tenant_id; schema isolation handles tenancy.

  attributes do
    # TimescaleDB hypertable - no traditional PK
    attribute :timestamp, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the metric was collected"
    end

    attribute :gateway_id, :string do
      allow_nil? false
      public? true
      description "Gateway that collected this metric"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent that collected this metric"
    end

    attribute :metric_name, :string do
      allow_nil? false
      public? true
      description "Name of the metric"
    end

    attribute :metric_type, :string do
      allow_nil? false
      public? true
      description "Type of metric (gauge, counter, histogram)"
    end

    attribute :device_id, :string do
      public? true
      description "Device ID this metric belongs to"
    end

    attribute :value, :float do
      allow_nil? false
      public? true
      description "Metric value"
    end

    attribute :unit, :string do
      public? true
      description "Unit of measurement"
    end

    attribute :tags, :map do
      public? true
      description "Tags for dimensional querying (JSONB)"
    end

    attribute :partition, :string do
      public? true
      description "Partition/segment identifier"
    end

    attribute :scale, :float do
      public? true
      description "Scale factor"
    end

    attribute :is_delta, :boolean do
      default false
      public? true
      description "Whether this is a delta value"
    end

    attribute :target_device_ip, :string do
      public? true
      description "Target device IP for SNMP/network metrics"
    end

    attribute :if_index, :integer do
      public? true
      description "Interface index for network metrics"
    end

    attribute :metadata, :map do
      public? true
      description "Additional metadata (JSONB)"
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the record was created"
    end
  end
end
