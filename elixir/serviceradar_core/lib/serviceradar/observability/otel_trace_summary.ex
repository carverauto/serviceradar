defmodule ServiceRadar.Observability.OtelTraceSummary do
  @moduledoc """
  OpenTelemetry trace summary resource.

  Maps to the `otel_trace_summaries` table for storing aggregated trace data.
  This is typically populated from a materialized view or CAGG that aggregates
  raw span data.
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
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # Timestamp - for query compatibility
    attribute :timestamp, :utc_datetime do
      allow_nil? false
      public? true
      description "Timestamp of the trace summary"
    end

    # Time bucket for aggregation
    attribute :time_bucket, :utc_datetime do
      public? true
      description "Time bucket for aggregation"
    end

    # Service identification
    attribute :service_name, :string do
      public? true
      description "Service name from OTel resource"
    end

    attribute :operation_name, :string do
      public? true
      description "Operation/span name"
    end

    # Aggregated metrics
    attribute :total_traces, :integer do
      default 0
      public? true
      description "Total number of traces in bucket"
    end

    attribute :error_traces, :integer do
      default 0
      public? true
      description "Number of traces with errors"
    end

    attribute :avg_duration_ms, :float do
      public? true
      description "Average trace duration in milliseconds"
    end

    attribute :min_duration_ms, :float do
      public? true
      description "Minimum trace duration in milliseconds"
    end

    attribute :max_duration_ms, :float do
      public? true
      description "Maximum trace duration in milliseconds"
    end

    attribute :p50_duration_ms, :float do
      public? true
      description "50th percentile duration"
    end

    attribute :p95_duration_ms, :float do
      public? true
      description "95th percentile duration"
    end

    attribute :p99_duration_ms, :float do
      public? true
      description "99th percentile duration"
    end

    # Throughput
    attribute :requests_per_second, :float do
      public? true
      description "Request rate in requests/second"
    end

    # Device references
    attribute :uid, :string do
      public? true
    end

    attribute :poller_id, :string do
      public? true
    end

    attribute :agent_id, :string do
      public? true
    end

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end
  end

  actions do
    defaults [:read]

    read :by_service do
      argument :service_name, :string, allow_nil?: false
      filter expr(service_name == ^arg(:service_name))
    end

    read :recent do
      filter expr(time_bucket > ago(24, :hour))
    end

    create :create do
      accept [
        :time_bucket, :service_name, :operation_name,
        :total_traces, :error_traces, :avg_duration_ms,
        :min_duration_ms, :max_duration_ms,
        :p50_duration_ms, :p95_duration_ms, :p99_duration_ms,
        :requests_per_second, :uid, :poller_id, :agent_id
      ]
    end
  end

  calculations do
    calculate :error_rate, :float, expr(
      cond do
        total_traces == 0 -> 0.0
        true -> (error_traces * 100.0) / total_traces
      end
    )

    calculate :success_traces, :integer, expr(
      total_traces - error_traces
    )
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
