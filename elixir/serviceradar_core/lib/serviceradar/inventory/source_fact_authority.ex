defmodule ServiceRadar.Inventory.SourceFactAuthority do
  @moduledoc """
  Operator-selected winner for a platform inventory fact.

  Rows live in the platform catalog, not in plugin manifests. `source_kind`
  identifies an integration source, plugin assignment, or source-type default.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "source_fact_authorities"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_enabled, action: :enabled
  end

  actions do
    defaults [:read]

    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [rank: :asc, inserted_at: :asc])
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_kind_ref_key

      accept [
        :source_kind,
        :source_ref,
        :source,
        :source_instance,
        :fact_key,
        :rank,
        :enabled
      ]
    end

    update :set_enabled do
      accept [:enabled, :rank, :source_instance]
    end

    destroy :destroy
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update, :destroy])
  end

  attributes do
    uuid_primary_key :id

    attribute :source_kind, :string, allow_nil?: false, public?: true
    attribute :source_ref, :string, allow_nil?: false, public?: true
    attribute :source, :string, allow_nil?: false, public?: true
    attribute :source_instance, :string, public?: true
    attribute :fact_key, :string, allow_nil?: false, public?: true
    attribute :rank, :integer, allow_nil?: false, default: 1, public?: true
    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :unique_kind_ref_key, [:source_kind, :source_ref, :fact_key]
  end
end
