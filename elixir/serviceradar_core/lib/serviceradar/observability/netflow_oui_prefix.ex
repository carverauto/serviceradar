defmodule ServiceRadar.Observability.NetflowOuiPrefix do
  @moduledoc """
  IEEE OUI prefixes for a specific snapshot.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "netflow_oui_prefixes"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    read :by_snapshot do
      argument :snapshot_id, :uuid, allow_nil?: false
      filter expr(snapshot_id == ^arg(:snapshot_id))
    end

    create :create do
      accept [:snapshot_id, :oui_prefix_int, :oui_prefix_hex, :organization]

      upsert? true
      upsert_identity :unique_snapshot_oui
      upsert_fields [:oui_prefix_hex, :organization]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :snapshot_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :oui_prefix_int, :integer do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :oui_prefix_hex, :string do
      allow_nil? false
      public? true
    end

    attribute :organization, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_snapshot_oui, [:snapshot_id, :oui_prefix_int]
  end
end
