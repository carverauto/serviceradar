defmodule ServiceRadar.Inventory.BumblebeeCatalogSource do
  @moduledoc """
  Operator-managed source for Bumblebee exposure catalog refreshes.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bumblebee_catalog_sources"
    repo ServiceRadar.Repo
    schema "platform"
  end

  paper_trail do
    primary_key_type :uuid
    table_name "bumblebee_catalog_source_versions"
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :url, :pinned_revision, :refresh_cron, :enabled, :metadata]
    end

    update :update do
      accept [:name, :url, :pinned_revision, :refresh_cron, :enabled, :metadata]
    end

    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [name: :asc])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :url, :string do
      allow_nil? false
      public? true
    end

    attribute :pinned_revision, :string do
      public? true
    end

    attribute :refresh_cron, :string do
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
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
    identity :unique_name, [:name]
  end
end
