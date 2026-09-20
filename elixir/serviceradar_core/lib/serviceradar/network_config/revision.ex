defmodule ServiceRadar.NetworkConfig.Revision do
  @moduledoc """
  Retrieved running or startup config for a canonical device.

  The body and content hash stay in CNPG. They are never written as Dgraph
  predicates. Duplicate `(device_uid, content_hash)` submissions are
  idempotent.
  """

  use Ash.Resource,
    domain: ServiceRadar.NetworkConfig,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "network_config_revisions"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    identity_index_names device_content_hash: "network_config_revisions_device_hash_uidx"
  end

  code_interface do
    define :create, action: :create
    define :latest_for_device, action: :latest_for_device, args: [:device_uid]
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :device_uid,
        :source,
        :config_kind,
        :retrieved_at,
        :content_hash,
        :body,
        :parser_version
      ]

      upsert? true
      upsert_identity :device_content_hash
      upsert_fields [:retrieved_at]
    end

    read :latest_for_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [retrieved_at: :desc], limit: 1)
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

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :source, :string do
      allow_nil? false
      public? true
    end

    attribute :config_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:running, :startup]
    end

    attribute :retrieved_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :content_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :body, :string do
      allow_nil? false
      public? true
      constraints allow_empty?: true, trim?: false
    end

    attribute :parser_version, :string do
      allow_nil? false
      default "network_config_v1"
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :device_content_hash, [:device_uid, :content_hash]
  end
end
