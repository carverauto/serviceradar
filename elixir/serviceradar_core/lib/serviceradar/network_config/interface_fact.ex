defmodule ServiceRadar.NetworkConfig.InterfaceFact do
  @moduledoc """
  Parsed interface stanza from a config revision.

  Facts are the rebuild source for config-declared topology. They are not
  the graph: Prefix / Interface updates are projected separately.
  """

  use Ash.Resource,
    domain: ServiceRadar.NetworkConfig,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "network_config_interface_facts"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    identity_index_names revision_if_name: "network_config_interface_facts_revision_if_uidx"
  end

  code_interface do
    define :create, action: :create
    define :by_revision, action: :by_revision, args: [:revision_id]
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :revision_id,
        :device_uid,
        :if_name,
        :ipv4_prefix,
        :ipv6_prefix,
        :vlan,
        :description,
        :shutdown,
        :vrf
      ]

      upsert? true
      upsert_identity :revision_if_name

      upsert_fields [
        :device_uid,
        :ipv4_prefix,
        :ipv6_prefix,
        :vlan,
        :description,
        :shutdown,
        :vrf
      ]
    end

    read :by_revision do
      argument :revision_id, :uuid, allow_nil?: false
      filter expr(revision_id == ^arg(:revision_id))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    operator_action_type(:create)
    read_all()
  end

  attributes do
    uuid_primary_key :id

    attribute :revision_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :if_name, :string do
      allow_nil? false
      public? true
    end

    attribute :ipv4_prefix, :string do
      public? true
    end

    attribute :ipv6_prefix, :string do
      public? true
    end

    attribute :vlan, :integer do
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :shutdown, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :vrf, :string do
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :revision_if_name, [:revision_id, :if_name]
  end
end
