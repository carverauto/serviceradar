defmodule ServiceRadar.Observability.OtelTraceSummary do
  @moduledoc """
  OpenTelemetry trace summary resource.

  Maps to the `otel_trace_summaries` materialized view. This is a read-only
  view that aggregates trace data from otel_traces. The schema matches the
  Go migration exactly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "otel_trace_summary"

    routes do
      base "/otel_trace_summaries"

      index :read
    end
  end

  postgres do
    table "otel_trace_summaries"
    repo ServiceRadar.Repo
    # Don't generate migrations - this is a materialized view managed by raw SQL
    migrate? false
  end

  # Note: No multitenancy - Go schema doesn't have tenant_id

  attributes do
    # Primary key is trace_id (unique index on materialized view)
    attribute :trace_id, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Unique trace identifier"
    end

    attribute :timestamp, :utc_datetime_usec do
      public? true
      description "Max timestamp from spans in this trace"
    end

    attribute :root_span_id, :string do
      public? true
      description "Span ID of the root span"
    end

    attribute :root_span_name, :string do
      public? true
      description "Name of the root span"
    end

    attribute :root_service_name, :string do
      public? true
      description "Service name of the root span"
    end

    attribute :root_span_kind, :integer do
      public? true
      description "Kind of the root span"
    end

    attribute :start_time_unix_nano, :integer do
      public? true
      description "Start time in nanoseconds since Unix epoch"
    end

    attribute :end_time_unix_nano, :integer do
      public? true
      description "End time in nanoseconds since Unix epoch"
    end

    attribute :duration_ms, :float do
      public? true
      description "Total trace duration in milliseconds"
    end

    attribute :status_code, :integer do
      public? true
      description "Status code of the root span"
    end

    attribute :status_message, :string do
      public? true
      description "Status message of the root span"
    end

    # Array of service names involved in this trace
    attribute :service_set, {:array, :string} do
      public? true
      description "List of services involved in this trace"
    end

    attribute :span_count, :integer do
      public? true
      description "Total number of spans in this trace"
    end

    attribute :error_count, :integer do
      public? true
      description "Number of spans with errors"
    end
  end

  actions do
    # Read-only - this is a materialized view
    defaults [:read]

    read :by_service do
      argument :service_name, :string, allow_nil?: false
      filter expr(root_service_name == ^arg(:service_name))
    end

    read :recent do
      description "Traces from the last 24 hours"
      filter expr(timestamp > ago(24, :hour))
    end

    read :with_errors do
      description "Traces that have errors"
      filter expr(error_count > 0)
    end
  end

  calculations do
    calculate :error_rate, :float, expr(
      cond do
        span_count == 0 -> 0.0
        true -> (error_count * 100.0) / span_count
      end
    )

    calculate :has_errors, :boolean, expr(error_count > 0)
  end

  policies do
    # Allow all reads - this data isn't tenant-scoped in Go
    policy action_type(:read) do
      authorize_if always()
    end
  end
end
