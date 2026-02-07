defmodule ServiceRadar.Observability.NetflowPortAnomalyFlag do
  @moduledoc """
  Cache table for simple port anomaly flags (per dst_port).
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "netflow_port_anomaly_flags"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    read :by_port do
      argument :dst_port, :integer, allow_nil?: false
      filter expr(dst_port == ^arg(:dst_port))
    end

    create :upsert do
      accept [
        :dst_port,
        :current_bytes,
        :baseline_bytes,
        :threshold_percent,
        :window_seconds,
        :window_end,
        :expires_at
      ]

      upsert? true
      upsert_identity :unique_dst_port

      upsert_fields [
        :current_bytes,
        :baseline_bytes,
        :threshold_percent,
        :window_seconds,
        :window_end,
        :expires_at,
        :updated_at
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:upsert) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action(:destroy) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :dst_port, :integer do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :current_bytes, :integer do
      allow_nil? false
      public? true
    end

    attribute :baseline_bytes, :integer do
      allow_nil? false
      public? true
    end

    attribute :threshold_percent, :integer do
      allow_nil? false
      public? true
    end

    attribute :window_seconds, :integer do
      allow_nil? false
      public? true
    end

    attribute :window_end, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_dst_port, [:dst_port]
  end
end

