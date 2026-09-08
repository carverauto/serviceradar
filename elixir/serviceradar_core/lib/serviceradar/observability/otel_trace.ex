defmodule ServiceRadar.Observability.OtelTrace do
  @moduledoc """
  OpenTelemetry trace/span resource.

  Maps to the `otel_traces` TimescaleDB hypertable. This table has a composite
  primary key (timestamp, trace_id, span_id) and is managed by raw SQL migrations
  that match the Go schema exactly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "otel_traces"
    repo ServiceRadar.Repo
    schema "platform"
    # Don't generate migrations - table is managed by raw SQL migration
    # that creates TimescaleDB hypertable with composite primary key
    migrate? false
  end

  json_api do
    type "otel_trace"
    # Composite primary key requires specifying which fields to use
    primary_key do
      keys [:timestamp, :trace_id, :span_id]
    end

    routes do
      base "/otel_traces"

      index :read
    end
  end

  # DB connection's search_path determines the schema

  actions do
    defaults [:read]

    read :by_trace do
      argument :trace_id, :string, allow_nil?: false
      filter expr(trace_id == ^arg(:trace_id))
    end

    read :by_service do
      argument :service_name, :string, allow_nil?: false
      filter expr(service_name == ^arg(:service_name))
    end

    read :recent do
      description "Traces from the last 24 hours"
      filter expr(timestamp > ago(24, :hour))
    end

    read :root_spans do
      description "Only root spans (no parent)"
      filter expr(is_nil(parent_span_id) or parent_span_id == "")
    end

    read :with_errors do
      description "Spans with error status"
      filter expr(status_code == 2)
    end

    create :create do
      accept [
        :timestamp,
        :trace_id,
        :span_id,
        :parent_span_id,
        :name,
        :kind,
        :start_time_unix_nano,
        :end_time_unix_nano,
        :service_name,
        :service_version,
        :service_instance,
        :scope_name,
        :scope_version,
        :scope_attributes,
        :status_code,
        :status_message,
        :trace_state,
        :attributes,
        :resource_attributes,
        :events,
        :links,
        :dropped_attributes_count,
        :dropped_events_count,
        :dropped_links_count,
        :service_namespace,
        :deployment_environment,
        :ingest_identity,
        :ingest_agent_id,
        :ingest_partition
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()

    policy action(:create) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    # Composite primary key matching Go schema
    attribute :timestamp, :utc_datetime_usec do
      primary_key? true
      allow_nil? false
      public? true
      description "When the span was recorded (part of composite PK)"
    end

    attribute :trace_id, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Trace ID (part of composite PK)"
    end

    attribute :span_id, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Span ID (part of composite PK)"
    end

    # Span relationships
    attribute :parent_span_id, :string do
      public? true
      description "Parent span ID (empty for root spans)"
    end

    attribute :name, :string do
      public? true
      description "Span name/operation"
    end

    attribute :kind, :integer do
      public? true

      description "Span kind (0=unspecified, 1=internal, 2=server, 3=client, 4=producer, 5=consumer)"
    end

    # Timing
    attribute :start_time_unix_nano, :integer do
      public? true
      description "Start time in nanoseconds since Unix epoch"
    end

    attribute :end_time_unix_nano, :integer do
      public? true
      description "End time in nanoseconds since Unix epoch"
    end

    # Service info
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

    attribute :service_namespace, :string do
      allow_nil? false
      default ""
      public? true
      description "Service namespace from OTel resource (service.namespace, '' when unset)"
    end

    attribute :deployment_environment, :string do
      allow_nil? false
      default ""
      public? true

      description "Deployment environment from OTel resource " <>
                    "(deployment.environment.name falling back to deployment.environment, '' when unset)"
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

    attribute :scope_attributes, :string do
      public? true
      description "Instrumentation scope attributes as sorted-key JSON (NULL when empty)"
    end

    # Status
    attribute :status_code, :integer do
      public? true
      description "Status code (0=unset, 1=ok, 2=error)"
    end

    attribute :status_message, :string do
      public? true
      description "Status message"
    end

    attribute :trace_state, :string do
      public? true
      description "W3C trace state (NULL when empty)"
    end

    # JSON-encoded fields (stored as TEXT in Go schema)
    attribute :attributes, :string do
      public? true
      description "Span attributes as JSON string"
    end

    attribute :resource_attributes, :string do
      public? true
      description "Resource attributes as JSON string"
    end

    attribute :events, :string do
      public? true
      description "Span events as JSON string"
    end

    attribute :links, :string do
      public? true
      description "Span links as JSON string"
    end

    # Span fidelity counters from the OTLP source
    attribute :dropped_attributes_count, :integer do
      allow_nil? false
      default 0
      public? true
      description "Number of span attributes dropped at the source"
    end

    attribute :dropped_events_count, :integer do
      allow_nil? false
      default 0
      public? true
      description "Number of span events dropped at the source"
    end

    attribute :dropped_links_count, :integer do
      allow_nil? false
      default 0
      public? true
      description "Number of span links dropped at the source"
    end

    # Ingest attribution (stamped by the agent gateway at publish time)
    attribute :ingest_identity, :string do
      allow_nil? false
      default ""
      public? true

      description "Publisher identity that ingested the span (Sr-Ingest-Identity header, '' when absent)"
    end

    attribute :ingest_agent_id, :string do
      allow_nil? false
      default ""
      public? true
      description "Agent that ingested the span (Sr-Agent-Id header, '' when absent)"
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
      description "When the record was created"
    end
  end

  calculations do
    calculate :duration_ms,
              :float,
              expr(
                if(
                  is_nil(start_time_unix_nano) or is_nil(end_time_unix_nano),
                  do: nil,
                  else: (end_time_unix_nano - start_time_unix_nano) / 1_000_000.0
                )
              )

    calculate :is_root, :boolean, expr(is_nil(parent_span_id) or parent_span_id == "")

    calculate :has_error, :boolean, expr(status_code == 2)
  end
end
