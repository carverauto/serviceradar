defmodule ServiceRadar.Observability.NetflowInterfaceCache do
  @moduledoc """
  Cache for NetFlow interface metadata keyed by `(sampler_address, if_index)`.

  This is a bounded lookup table to support SRQL dimensions like `in_if_name`/`out_if_name`
  and future capacity-based units.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "netflow_interface_cache"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [
        :sampler_address,
        :if_index,
        :device_uid,
        :if_name,
        :if_description,
        :if_speed_bps,
        :boundary,
        :refreshed_at
      ]

      upsert? true
      upsert_identity :unique_sampler_ifindex

      upsert_fields [
        :device_uid,
        :if_name,
        :if_description,
        :if_speed_bps,
        :boundary,
        :refreshed_at,
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
  end

  attributes do
    attribute :sampler_address, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :if_index, :integer do
      primary_key? true
      allow_nil? false
      public? true
      description "Interface index (SNMP ifIndex) from flow exporter"
    end

    attribute :device_uid, :string do
      public? true
    end

    attribute :if_name, :string do
      public? true
    end

    attribute :if_description, :string do
      public? true
    end

    attribute :if_speed_bps, :integer do
      public? true
    end

    attribute :boundary, :string do
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
    identity :unique_sampler_ifindex, [:sampler_address, :if_index]
  end
end
