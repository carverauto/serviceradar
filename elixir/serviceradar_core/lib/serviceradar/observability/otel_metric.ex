defmodule ServiceRadar.Observability.OtelMetric do
  @moduledoc """
  OpenTelemetry metric resource.

  Maps to the `otel_metrics` TimescaleDB hypertable. This table has a composite
  primary key (timestamp, span_name, service_name, span_id) and is managed by
  raw SQL migrations that match the Go schema exactly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "otel_metric"
    # Composite primary key requires specifying which fields to use
    primary_key do
      keys [:timestamp, :span_name, :service_name, :span_id]
    end

    routes do
      base "/otel_metrics"

      index :read
    end
  end

  postgres do
    table "otel_metrics"
    repo ServiceRadar.Repo
    # Don't generate migrations - table is managed by raw SQL migration
    # that creates TimescaleDB hypertable with composite primary key
    migrate? false
  end

  # Note: No multitenancy - Go schema doesn't have tenant_id

  attributes do
    # Composite primary key matching Go schema
    attribute :timestamp, :utc_datetime_usec do
      primary_key? true
      allow_nil? false
      public? true
      description "When the metric was collected (part of composite PK)"
    end

    attribute :span_name, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Name of the span (part of composite PK)"
    end

    attribute :service_name, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Service name (part of composite PK)"
    end

    attribute :span_id, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Span ID (part of composite PK)"
    end

    # Other attributes matching Go schema exactly
    attribute :trace_id, :string do
      public? true
      description "Trace ID for correlation"
    end

    attribute :span_kind, :string do
      public? true
      description "Kind of span (client, server, producer, consumer, internal)"
    end

    attribute :duration_ms, :float do
      public? true
      description "Duration in milliseconds"
    end

    attribute :duration_seconds, :float do
      public? true
      description "Duration in seconds"
    end

    attribute :metric_type, :string do
      public? true
      description "Type of metric"
    end

    attribute :http_method, :string do
      public? true
      description "HTTP method (GET, POST, etc.)"
    end

    attribute :http_route, :string do
      public? true
      description "HTTP route/path"
    end

    attribute :http_status_code, :string do
      public? true
      description "HTTP response status code"
    end

    attribute :grpc_service, :string do
      public? true
      description "gRPC service name"
    end

    attribute :grpc_method, :string do
      public? true
      description "gRPC method name"
    end

    # TEXT in Go schema, not INTEGER
    attribute :grpc_status_code, :string do
      public? true
      description "gRPC status code (as string)"
    end

    attribute :is_slow, :boolean do
      public? true
      description "Whether this metric represents a slow operation"
    end

    attribute :component, :string do
      public? true
      description "Component name"
    end

    attribute :level, :string do
      public? true
      description "Log level or severity"
    end

    attribute :unit, :string do
      public? true
      description "Unit of measurement"
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the record was created"
    end
  end

  actions do
    defaults [:read]

    read :by_service do
      argument :service_name, :string, allow_nil?: false
      filter expr(service_name == ^arg(:service_name))
    end

    read :recent do
      description "Metrics from the last 24 hours"
      filter expr(timestamp > ago(24, :hour))
    end

    read :slow_operations do
      description "Slow operations only"
      filter expr(is_slow == true)
    end

    create :create do
      accept [
        :timestamp, :span_name, :service_name, :span_id,
        :trace_id, :span_kind, :duration_ms, :duration_seconds,
        :metric_type, :http_method, :http_route, :http_status_code,
        :grpc_service, :grpc_method, :grpc_status_code,
        :is_slow, :component, :level, :unit
      ]
    end
  end

  policies do
    # For now, allow all reads - this data isn't tenant-scoped in Go
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end
  end
end
