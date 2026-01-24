defmodule ServiceRadar.Observability.ServiceStatus do
  @moduledoc """
  Service status resource backed by the `service_status` TimescaleDB hypertable.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "service_status"
    repo ServiceRadar.Repo
    migrate? false
  end

  json_api do
    type "service_status"

    primary_key do
      keys [:timestamp, :gateway_id, :service_name]
    end

    routes do
      base "/service_status"

      index :read
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :timestamp,
        :gateway_id,
        :agent_id,
        :service_name,
        :service_type,
        :available,
        :message,
        :details,
        :partition,
        :created_at
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end
  end

  attributes do
    attribute :timestamp, :utc_datetime_usec do
      primary_key? true
      allow_nil? false
      public? true
      description "When the status was observed"
    end

    attribute :gateway_id, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Gateway that reported the status"
    end

    attribute :service_name, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Service name"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent that reported the status"
    end

    attribute :service_type, :string do
      public? true
      description "Service type"
    end

    attribute :available, :boolean do
      allow_nil? false
      public? true
      description "Availability status"
    end

    attribute :message, :string do
      public? true
      description "Short status summary"
    end

    attribute :details, :string do
      public? true
      description "Structured details (JSON encoded)"
    end

    attribute :partition, :string do
      public? true
      description "Partition identifier"
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the record was created"
    end
  end
end
