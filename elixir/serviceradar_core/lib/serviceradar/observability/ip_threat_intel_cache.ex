defmodule ServiceRadar.Observability.IpThreatIntelCache do
  @moduledoc """
  Cache for per-IP threat intel matches.

  This keeps UI lookups cheap without re-evaluating indicator membership constantly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ip_threat_intel_cache"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    read :by_ip do
      argument :ip, :string, allow_nil?: false
      filter expr(ip == ^arg(:ip))
    end

    create :upsert do
      accept [
        :ip,
        :matched,
        :match_count,
        :max_severity,
        :sources,
        :looked_up_at,
        :expires_at,
        :error,
        :error_count
      ]

      upsert? true
      upsert_identity :unique_ip

      upsert_fields [
        :matched,
        :match_count,
        :max_severity,
        :sources,
        :looked_up_at,
        :expires_at,
        :error,
        :error_count,
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
    attribute :ip, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :matched, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :match_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :max_severity, :integer do
      public? true
    end

    attribute :sources, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :looked_up_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :error, :string do
      public? true
    end

    attribute :error_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_ip, [:ip]
  end
end
