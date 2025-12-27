defmodule ServiceRadar.Observability.TimeseriesMetric do
  @moduledoc """
  Generic time-series metric resource.

  Maps to the `timeseries_metrics` table for storing various metrics types.
  Uses TimescaleDB hypertable for efficient time-series storage and querying.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "timeseries_metric"

    routes do
      base "/timeseries_metrics"

      index :read
    end
  end

  postgres do
    table "timeseries_metrics"
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
      allow_nil? false
      public? true
      description "Name of the metric"
    end

    attribute :metric_type, :string do
      public? true
      description "Type of metric (gauge, counter, histogram)"
    end

    # Metric value
    attribute :value, :float do
      public? true
      description "Metric value"
    end

    # Device/infrastructure references
    attribute :uid, :string do
      public? true
      description "Device UID this metric belongs to"
    end

    attribute :poller_id, :string do
      public? true
      description "Poller that collected this metric"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent that collected this metric"
    end

    attribute :target_device_ip, :string do
      public? true
      description "Target device IP for SNMP/network metrics"
    end

    # Categorization
    attribute :partition, :string do
      public? true
      description "Partition/segment identifier"
    end

    attribute :if_index, :integer do
      public? true
      description "Interface index for network metrics"
    end

    # Structured labels
    attribute :labels, :map do
      default %{}
      public? true
      description "Metric labels for dimensional querying"
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

    read :by_device do
      argument :uid, :string, allow_nil?: false
      filter expr(uid == ^arg(:uid))
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
        :uid, :poller_id, :agent_id, :target_device_ip,
        :partition, :if_index, :labels
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
