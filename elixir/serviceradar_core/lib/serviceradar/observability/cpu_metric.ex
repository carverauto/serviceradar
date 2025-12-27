defmodule ServiceRadar.Observability.CpuMetric do
  @moduledoc """
  CPU utilization metric resource.

  Maps to the `cpu_metrics` table for storing CPU utilization data.
  Uses TimescaleDB hypertable for efficient time-series storage.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "cpu_metric"

    routes do
      base "/cpu_metrics"

      index :read
    end
  end

  postgres do
    table "cpu_metrics"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :timestamp, :utc_datetime do
      allow_nil? false
      public? true
    end

    # CPU metrics
    attribute :user_pct, :float do
      public? true
      description "User CPU percentage"
    end

    attribute :system_pct, :float do
      public? true
      description "System CPU percentage"
    end

    attribute :idle_pct, :float do
      public? true
      description "Idle CPU percentage"
    end

    attribute :iowait_pct, :float do
      public? true
      description "IO wait CPU percentage"
    end

    attribute :steal_pct, :float do
      public? true
      description "Steal CPU percentage (virtualization)"
    end

    # Core identification
    attribute :core_id, :string do
      public? true
      description "CPU core identifier"
    end

    attribute :label, :string do
      public? true
      description "CPU label"
    end

    # Device references
    attribute :uid, :string do
      public? true
    end

    attribute :host_id, :string do
      public? true
    end

    attribute :poller_id, :string do
      public? true
    end

    attribute :agent_id, :string do
      public? true
    end

    attribute :partition, :string do
      public? true
    end

    attribute :cluster, :string do
      public? true
    end

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :uid, :string, allow_nil?: false
      filter expr(uid == ^arg(:uid))
    end

    read :recent do
      filter expr(timestamp > ago(24, :hour))
    end

    create :create do
      accept [
        :timestamp, :user_pct, :system_pct, :idle_pct, :iowait_pct, :steal_pct,
        :core_id, :label, :uid, :host_id, :poller_id, :agent_id, :partition, :cluster
      ]
    end
  end

  calculations do
    calculate :total_used_pct, :float, expr(
      100.0 - (idle_pct || 0.0)
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
