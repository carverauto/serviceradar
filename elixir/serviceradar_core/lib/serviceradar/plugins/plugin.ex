defmodule ServiceRadar.Plugins.Plugin do
  @moduledoc """
  Plugin root record that spans all versions of a Wasm plugin.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "plugins"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:plugin_id, :name, :description, :source_repo_url, :homepage_url, :disabled]
    end

    update :update do
      accept [:name, :description, :source_repo_url, :homepage_url, :disabled]
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    manage_action_types()
  end

  attributes do
    attribute :plugin_id, :string do
      allow_nil? false
      primary_key? true
      public? true
      description "Stable plugin identifier (manifest id)"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Display name for the plugin"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :source_repo_url, :string do
      allow_nil? true
      public? true
    end

    attribute :homepage_url, :string do
      allow_nil? true
      public? true
    end

    attribute :disabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :packages, ServiceRadar.Plugins.PluginPackage do
      source_attribute :plugin_id
      destination_attribute :plugin_id
      public? true
    end
  end
end
