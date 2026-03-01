defmodule ServiceRadar.Observability.IpGeoEnrichmentCache do
  @moduledoc """
  Cache for IP GeoIP/ASN enrichment.

  This is a bounded cache keyed by IP:
  - one row per IP
  - `expires_at` controls TTL
  - background jobs refresh and prune expired rows
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ip_geo_enrichment_cache"
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
        :asn,
        :as_org,
        :country_iso2,
        :country_name,
        :region,
        :city,
        :latitude,
        :longitude,
        :timezone,
        :is_private,
        :looked_up_at,
        :expires_at,
        :error,
        :error_count
      ]

      upsert? true
      upsert_identity :unique_ip

      upsert_fields [
        :asn,
        :as_org,
        :country_iso2,
        :country_name,
        :region,
        :city,
        :latitude,
        :longitude,
        :timezone,
        :is_private,
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
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:upsert) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
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

    attribute :asn, :integer do
      public? true
    end

    attribute :as_org, :string do
      public? true
    end

    attribute :country_iso2, :string do
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

    attribute :latitude, :float do
      public? true
    end

    attribute :longitude, :float do
      public? true
    end

    attribute :timezone, :string do
      public? true
    end

    attribute :is_private, :boolean do
      allow_nil? false
      default false
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
