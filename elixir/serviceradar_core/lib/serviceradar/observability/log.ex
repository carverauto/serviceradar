defmodule ServiceRadar.Observability.Log do
  @moduledoc """
  Log entry resource for observability (OpenTelemetry-aligned).

  Maps to the `logs` TimescaleDB hypertable. This table has a composite
  primary key (timestamp, id) and is managed by raw SQL migrations.

  Promotion metadata is stored in `attributes["serviceradar.ingest"]`,
  including NATS subject, received_at, and source_kind.

  ## OpenTelemetry Severity Numbers

  - 1-4: TRACE
  - 5-8: DEBUG
  - 9-12: INFO
  - 13-16: WARN
  - 17-20: ERROR
  - 21-24: FATAL
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "logs"
    repo ServiceRadar.Repo
    schema "platform"
    # Don't generate migrations - table is managed by raw SQL migration
    # that creates TimescaleDB hypertable with composite primary key
    migrate? false
  end

  json_api do
    type "log"
    # Composite primary key requires specifying which fields to use
    primary_key do
      keys [:timestamp, :id]
    end

    routes do
      base "/logs"

      index :read
    end
  end

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

    read :by_severity do
      argument :min_severity, :integer, allow_nil?: false
      filter expr(severity_number >= ^arg(:min_severity))
    end

    read :recent do
      description "Logs from the last 24 hours"
      filter expr(timestamp > ago(24, :hour))
    end

    create :create do
      accept [
        :timestamp,
        :observed_timestamp,
        :trace_id,
        :span_id,
        :trace_flags,
        :severity_text,
        :severity_number,
        :body,
        :event_name,
        :source,
        :service_name,
        :service_version,
        :service_instance,
        :scope_name,
        :scope_version,
        :scope_attributes,
        :attributes,
        :resource_attributes
      ]
    end
  end

  policies do
    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Read access: Must be authenticated
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Create logs: Operators/admins
    policy action(:create) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  changes do
  end

  attributes do
    # Composite primary key for TimescaleDB hypertable compatibility
    # timestamp must be part of PK for hypertable partitioning
    attribute :timestamp, :utc_datetime_usec do
      primary_key? true
      allow_nil? false
      public? true
      description "When the log entry was generated (part of composite PK)"
    end

    attribute :observed_timestamp, :utc_datetime_usec do
      public? true
      description "When the log entry was observed by the collector"
    end

    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      default &Ash.UUID.generate/0
      public? true
      description "Unique log entry ID (part of composite PK)"
    end

    # OpenTelemetry trace context
    attribute :trace_id, :string do
      public? true
      description "Trace ID for correlation"
    end

    attribute :span_id, :string do
      public? true
      description "Span ID for correlation"
    end

    attribute :trace_flags, :integer do
      public? true
      description "W3C trace flags"
    end

    # OpenTelemetry severity
    attribute :severity_text, :string do
      public? true
      description "Severity level name (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)"
    end

    attribute :severity_number, :integer do
      public? true
      description "OpenTelemetry severity number (1-24)"
    end

    # Log body/message
    attribute :body, :string do
      public? true
      description "Log message body"
    end

    attribute :event_name, :string do
      public? true
      description "Event name identifying the log record type"
    end

    attribute :source, :string do
      public? true
      description "Log source (syslog, otel, snmp, internal, etc)"
    end

    # Service identification (from Resource)
    attribute :service_name, :string do
      public? true
      description "Service name from OTel resource"
    end

    attribute :service_version, :string do
      public? true
      description "Service version from OTel resource"
    end

    attribute :service_instance, :string do
      public? true
      description "Service instance ID from OTel resource"
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
      description "Instrumentation scope attributes"
    end

    # Structured attributes (stored as TEXT by db-event-writer)
    attribute :attributes, :string do
      public? true
      description "Log record attributes"
    end

    attribute :resource_attributes, :string do
      public? true
      description "Resource attributes"
    end

    # Timestamps
    create_timestamp :created_at
  end

  calculations do
    calculate :severity_label,
              :string,
              expr(
                cond do
                  not is_nil(severity_text) -> severity_text
                  severity_number >= 21 -> "FATAL"
                  severity_number >= 17 -> "ERROR"
                  severity_number >= 13 -> "WARN"
                  severity_number >= 9 -> "INFO"
                  severity_number >= 5 -> "DEBUG"
                  severity_number >= 1 -> "TRACE"
                  true -> "UNSPECIFIED"
                end
              )

    calculate :severity_color,
              :string,
              expr(
                cond do
                  severity_number >= 21 -> "red"
                  severity_number >= 17 -> "orange"
                  severity_number >= 13 -> "yellow"
                  severity_number >= 9 -> "blue"
                  true -> "gray"
                end
              )
  end
end
