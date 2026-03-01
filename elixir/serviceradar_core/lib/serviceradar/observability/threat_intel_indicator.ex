defmodule ServiceRadar.Observability.ThreatIntelIndicator do
  @moduledoc """
  Threat intelligence indicators (CIDR-based).

  Indicators are populated by background feed refresh jobs.
  Query-time checks should rely on DB indexes (GIST on CIDR).
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "threat_intel_indicators"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [
        :indicator,
        :indicator_type,
        :source,
        :label,
        :severity,
        :confidence,
        :first_seen_at,
        :last_seen_at,
        :expires_at
      ]

      upsert? true
      upsert_identity :unique_source_indicator

      upsert_fields [
        :indicator_type,
        :label,
        :severity,
        :confidence,
        :last_seen_at,
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
    uuid_primary_key :id

    attribute :indicator, ServiceRadar.Types.Cidr do
      allow_nil? false
      public? true
      description "CIDR indicator"
    end

    attribute :indicator_type, :string do
      allow_nil? false
      default "cidr"
      public? true
    end

    attribute :source, :string do
      allow_nil? false
      public? true
    end

    attribute :label, :string do
      public? true
    end

    attribute :severity, :integer do
      public? true
    end

    attribute :confidence, :integer do
      public? true
    end

    attribute :first_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_source_indicator, [:source, :indicator]
  end
end
