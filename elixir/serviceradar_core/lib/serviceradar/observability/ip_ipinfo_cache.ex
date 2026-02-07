defmodule ServiceRadar.Observability.IpIpinfoCache do
  @moduledoc """
  Cache for ipinfo.io/lite enrichment.

  Bounded by IP with TTL (`expires_at`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ip_ipinfo_cache"
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
        :country_code,
        :country_name,
        :region,
        :city,
        :timezone,
        :as_number,
        :as_name,
        :as_domain,
        :looked_up_at,
        :expires_at,
        :error,
        :error_count
      ]

      upsert? true
      upsert_identity :unique_ip

      upsert_fields [
        :country_code,
        :country_name,
        :region,
        :city,
        :timezone,
        :as_number,
        :as_name,
        :as_domain,
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
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
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

    attribute :country_code, :string do
      public? true
    end

    attribute :country_name, :string do
      public? true
    end

    attribute :region, :string do
      public? true
    end

    attribute :city, :string do
      public? true
    end

    attribute :timezone, :string do
      public? true
    end

    attribute :as_number, :integer do
      public? true
    end

    attribute :as_name, :string do
      public? true
    end

    attribute :as_domain, :string do
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

