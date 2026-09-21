defmodule ServiceRadar.NetworkChanges.Change do
  @moduledoc """
  CNPG change record. Ticket comments stay here; the graph node is id,
  kind, window, status, source, and affects only.
  """

  use Ash.Resource,
    domain: ServiceRadar.NetworkChanges,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "network_changes"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    identity_index_names source_external_id: "network_changes_source_external_uidx"
  end

  code_interface do
    define :create, action: :create
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :external_id,
        :source,
        :kind,
        :window_start,
        :window_end,
        :status,
        :selector,
        :comments
      ]

      upsert? true
      upsert_identity :source_external_id
      upsert_fields [:kind, :window_start, :window_end, :status, :selector, :comments]
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

    attribute :external_id, :string do
      allow_nil? false
      public? true
    end

    attribute :source, :string do
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:upgrade, :config, :other]
    end

    attribute :window_start, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :window_end, :utc_datetime_usec do
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      public? true
    end

    attribute :selector, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :comments, :string do
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :source_external_id, [:source, :external_id]
  end
end
