defmodule ServiceRadar.Observability.NetflowExporterCache do
  @moduledoc """
  Cache for NetFlow exporter metadata keyed by `sampler_address`.

  This is a bounded lookup table to support SRQL dimensions like `exporter_name`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "netflow_exporter_cache"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [:sampler_address, :exporter_name, :device_uid, :refreshed_at]

      upsert? true
      upsert_identity :unique_sampler_address

      upsert_fields [:exporter_name, :device_uid, :refreshed_at, :updated_at]
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
  end

  attributes do
    attribute :sampler_address, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :exporter_name, :string do
      public? true
    end

    attribute :device_uid, :string do
      public? true
    end

    attribute :refreshed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_sampler_address, [:sampler_address]
  end
end
