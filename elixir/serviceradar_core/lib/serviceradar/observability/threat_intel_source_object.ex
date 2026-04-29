defmodule ServiceRadar.Observability.ThreatIntelSourceObject do
  @moduledoc """
  Provider object metadata for threat-intel imports.

  Indicator rows stay small and optimized for CIDR matching; this resource keeps
  STIX/TAXII/OTX object identity and raw context for later hit explanation.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @upsert_fields [
    :provider,
    :source,
    :collection_id,
    :object_id,
    :object_type,
    :object_version,
    :spec_version,
    :date_added,
    :modified_at,
    :raw_object_key,
    :metadata
  ]

  postgres do
    table "threat_intel_source_objects"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept @upsert_fields

      upsert? true
      upsert_identity :unique_source_object

      upsert_fields [
        :provider,
        :object_type,
        :spec_version,
        :date_added,
        :modified_at,
        :raw_object_key,
        :metadata,
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

    attribute :provider, :string do
      allow_nil? false
      public? true
    end

    attribute :source, :string do
      allow_nil? false
      public? true
    end

    attribute :collection_id, :string do
      public? true
    end

    attribute :object_id, :string do
      allow_nil? false
      public? true
    end

    attribute :object_type, :string do
      allow_nil? false
      public? true
    end

    attribute :object_version, :string do
      allow_nil? false
      default ""
      public? true
    end

    attribute :spec_version, :string do
      public? true
    end

    attribute :date_added, :utc_datetime_usec do
      public? true
    end

    attribute :modified_at, :utc_datetime_usec do
      public? true
    end

    attribute :raw_object_key, :string do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_source_object, [:source, :collection_id, :object_id, :object_version]
  end
end
