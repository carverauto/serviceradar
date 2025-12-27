defmodule ServiceRadar.Observability.Log do
  @moduledoc """
  Log entry resource for observability (OpenTelemetry-aligned).

  Maps to the `logs` table with OpenTelemetry Logs Data Model attributes.
  Logs are ingested from pollers, agents, and external sources via OTLP.

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

  json_api do
    type "log"

    routes do
      base "/logs"

      index :read
    end
  end

  postgres do
    table "logs"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    # Primary key
    uuid_primary_key :id

    # Timestamp - when the log was generated
    attribute :timestamp, :utc_datetime do
      allow_nil? false
      public? true
      description "When the log entry was generated"
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

    # Structured attributes
    attribute :attributes, :map do
      default %{}
      public? true
      description "Log record attributes"
    end

    attribute :resource_attributes, :map do
      default %{}
      public? true
      description "Resource attributes"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this log belongs to"
    end

    # Timestamps
    create_timestamp :created_at
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
        :timestamp, :trace_id, :span_id, :severity_text, :severity_number,
        :body, :service_name, :service_version, :service_instance,
        :scope_name, :scope_version, :attributes, :resource_attributes
      ]
    end
  end

  calculations do
    calculate :severity_label, :string, expr(
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

    calculate :severity_color, :string, expr(
      cond do
        severity_number >= 21 -> "red"
        severity_number >= 17 -> "orange"
        severity_number >= 13 -> "yellow"
        severity_number >= 9 -> "blue"
        true -> "gray"
      end
    )
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Read access: Must be authenticated AND in same tenant
    policy action_type(:read) do
      authorize_if expr(
        ^actor(:role) in [:viewer, :operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end

    # Create logs: Operators/admins, enforces tenant from context
    policy action(:create) do
      authorize_if expr(
        ^actor(:role) in [:operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end
  end
end
