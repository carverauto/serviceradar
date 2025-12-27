defmodule ServiceRadar.Observability.OtelMetric do
  @moduledoc """
  OpenTelemetry metric resource.

  Maps to the `otel_metrics` table for storing OpenTelemetry metrics data.
  Uses TimescaleDB hypertable for efficient time-series storage.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "otel_metric"

    routes do
      base "/otel_metrics"

      index :read
    end
  end

  postgres do
    table "otel_metrics"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # Timestamp - primary dimension for TimescaleDB
    attribute :timestamp, :utc_datetime do
      allow_nil? false
      public? true
      description "When the metric was collected"
    end

    # Metric identification
    attribute :metric_name, :string do
      public? true
      description "Name of the metric"
    end

    attribute :metric_type, :string do
      public? true
      description "Type of metric (gauge, counter, histogram, sum)"
    end

    # Metric value
    attribute :value, :float do
      public? true
      description "Metric value"
    end

    # Service identification (from Resource)
    attribute :service_name, :string do
      public? true
      description "Service name from OTel resource"
    end

    attribute :service_version, :string do
      public? true
      description "Service version"
    end

    attribute :service_instance, :string do
      public? true
      description "Service instance ID"
    end

    # Instrumentation scope
    attribute :scope_name, :string do
      public? true
      description "Instrumentation scope name"
    end

    attribute :scope_version, :string do
      public? true
      description "Instrumentation scope version"
    end

    # Structured attributes
    attribute :attributes, :map do
      default %{}
      public? true
      description "Metric attributes/labels"
    end

    attribute :resource_attributes, :map do
      default %{}
      public? true
      description "Resource attributes"
    end

    # Performance flags
    attribute :is_slow, :boolean do
      default false
      public? true
      description "Whether this metric represents a slow operation"
    end

    # HTTP-specific attributes (for HTTP metrics)
    attribute :http_status_code, :string do
      public? true
      description "HTTP response status code"
    end

    attribute :http_method, :string do
      public? true
      description "HTTP method (GET, POST, etc.)"
    end

    attribute :http_route, :string do
      public? true
      description "HTTP route/path"
    end

    attribute :duration_ms, :float do
      public? true
      description "Duration in milliseconds"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this metric belongs to"
    end
  end

  actions do
    defaults [:read]

    read :by_service do
      argument :service_name, :string, allow_nil?: false
      filter expr(service_name == ^arg(:service_name))
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
        :timestamp, :metric_name, :metric_type, :value,
        :service_name, :service_version, :service_instance,
        :scope_name, :scope_version, :attributes, :resource_attributes,
        :is_slow, :http_status_code, :http_method, :http_route, :duration_ms
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action_type(:read) do
      authorize_if expr(
        ^actor(:role) in [:viewer, :operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end

    policy action(:create) do
      authorize_if expr(
        ^actor(:role) in [:operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end
  end
end
