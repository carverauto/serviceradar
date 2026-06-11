defmodule ServiceRadar.Observability.OtelMetricPoint do
  @moduledoc """
  OpenTelemetry metric data point resource.

  Maps to the `otel_metric_points` TimescaleDB hypertable holding real OTLP
  sum/gauge/histogram data points (distinct from the span-derived samples in
  `otel_metrics`). The table has a composite primary key
  (timestamp, metric_name, service_name, attributes_hash) and is managed by
  a raw SQL migration; rows are written by the EventWriter OtelMetrics
  processor, so this resource is read-only.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "otel_metric_points"
    repo ServiceRadar.Repo
    schema "platform"
    # Don't generate migrations - table is managed by raw SQL migration
    # that creates TimescaleDB hypertable with composite primary key
    migrate? false
  end

  json_api do
    type "otel_metric_point"
    # Composite primary key requires specifying which fields to use
    primary_key do
      keys [:timestamp, :metric_name, :service_name, :attributes_hash]
    end

    routes do
      base "/otel_metric_points"

      index :read
    end
  end

  # DB connection's search_path determines the schema

  actions do
    defaults [:read]

    read :by_metric do
      argument :metric_name, :string, allow_nil?: false
      filter expr(metric_name == ^arg(:metric_name))
    end

    read :by_service do
      argument :service_name, :string, allow_nil?: false
      filter expr(service_name == ^arg(:service_name))
    end

    read :recent do
      description "Metric points from the last 24 hours"
      filter expr(timestamp > ago(24, :hour))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    # Composite primary key matching the raw SQL schema
    attribute :timestamp, :utc_datetime_usec do
      primary_key? true
      allow_nil? false
      public? true
      description "Data point time (part of composite PK)"
    end

    attribute :metric_name, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "OTLP metric name (part of composite PK)"
    end

    attribute :service_name, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Resource service.name (part of composite PK)"
    end

    attribute :attributes_hash, :string do
      primary_key? true
      allow_nil? false
      public? true

      description "Recipe-v2 identity hash: MD5 of canonical attribute bytes + " <>
                    "service_instance_id + scope_name (part of composite PK)"
    end

    attribute :metric_type, :string do
      public? true
      description "Metric type: sum, gauge, or histogram"
    end

    attribute :unit, :string do
      public? true
      description "Unit of measurement"
    end

    attribute :temporality, :string do
      public? true
      description "Aggregation temporality (delta, cumulative, unspecified)"
    end

    attribute :is_monotonic, :boolean do
      public? true
      description "Whether a sum metric is monotonic (sums only)"
    end

    attribute :attributes, :string do
      public? true
      description "Data point attributes as JSON text (keys sorted at every nesting level)"
    end

    attribute :service_instance_id, :string do
      allow_nil? false
      default ""
      public? true
      description "Resource service.instance.id ('' when absent); folded into attributes_hash"
    end

    attribute :scope_name, :string do
      allow_nil? false
      default ""
      public? true
      description "Instrumentation scope name ('' when absent); folded into attributes_hash"
    end

    attribute :start_time_unix_nano, :integer do
      public? true
      description "Data point start time in unix nanoseconds (NULL when absent/zero)"
    end

    attribute :value, :float do
      public? true
      description "Point value for sums and gauges"
    end

    attribute :count, :integer do
      public? true
      description "Histogram observation count"
    end

    attribute :sum, :float do
      public? true
      description "Histogram sum of observations"
    end

    attribute :bucket_counts, :string do
      public? true
      description "Histogram bucket counts as JSON text"
    end

    attribute :explicit_bounds, :string do
      public? true
      description "Histogram explicit bucket bounds as JSON text"
    end

    # Ingest attribution (stamped by the agent gateway at publish time)
    attribute :ingest_identity, :string do
      allow_nil? false
      default ""
      public? true

      description "Publisher identity that ingested the point (Sr-Ingest-Identity header, '' when absent)"
    end

    attribute :ingest_agent_id, :string do
      allow_nil? false
      default ""
      public? true
      description "Agent that ingested the point (Sr-Agent-Id header, '' when absent)"
    end

    attribute :ingest_partition, :string do
      allow_nil? false
      default ""
      public? true
      description "Partition/site of the ingesting agent (Sr-Partition header, '' when absent)"
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the record was ingested"
    end
  end
end
