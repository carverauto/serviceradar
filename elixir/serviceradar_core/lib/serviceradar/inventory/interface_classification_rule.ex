defmodule ServiceRadar.Inventory.InterfaceClassificationRule do
  @moduledoc """
  Rule definitions for interface classification.

  Rules are evaluated in priority order to tag interfaces with classifications
  such as management, wan, or wireguard.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "interface_classification_rules"
    repo ServiceRadar.Repo
  end

  json_api do
    type "interface_classification_rule"

    routes do
      base "/interface-classification-rules"
      index :read
      get :by_id
    end
  end

  code_interface do
    define :get, action: :by_id, args: [:id]
    define :list, action: :read
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    create :create do
      accept [
        :name,
        :enabled,
        :priority,
        :vendor_pattern,
        :model_pattern,
        :sys_descr_pattern,
        :if_name_pattern,
        :if_descr_pattern,
        :if_alias_pattern,
        :if_type_ids,
        :ip_cidr_allow,
        :ip_cidr_deny,
        :classifications,
        :metadata
      ]
    end

    update :update do
      accept [
        :name,
        :enabled,
        :priority,
        :vendor_pattern,
        :model_pattern,
        :sys_descr_pattern,
        :if_name_pattern,
        :if_descr_pattern,
        :if_alias_pattern,
        :if_type_ids,
        :ip_cidr_allow,
        :ip_cidr_deny,
        :classifications,
        :metadata
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:read) do
      authorize_if expr(^actor(:role) in [:viewer, :operator, :admin])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Rule name"
    end

    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether the rule is active"
    end

    attribute :priority, :integer do
      default 0
      public? true
      description "Rule priority (higher wins)"
    end

    attribute :vendor_pattern, :string do
      public? true
      description "Regex pattern for device vendor match"
    end

    attribute :model_pattern, :string do
      public? true
      description "Regex pattern for device model match"
    end

    attribute :sys_descr_pattern, :string do
      public? true
      description "Regex pattern for device sysDescr match"
    end

    attribute :if_name_pattern, :string do
      public? true
      description "Regex pattern for interface name match"
    end

    attribute :if_descr_pattern, :string do
      public? true
      description "Regex pattern for interface description match"
    end

    attribute :if_alias_pattern, :string do
      public? true
      description "Regex pattern for interface alias match"
    end

    attribute :if_type_ids, {:array, :integer} do
      default []
      public? true
      description "Interface type IDs (ifType) to match"
    end

    attribute :ip_cidr_allow, {:array, :string} do
      default []
      public? true
      description "CIDR ranges to allow for IP match"
    end

    attribute :ip_cidr_deny, {:array, :string} do
      default []
      public? true
      description "CIDR ranges to deny for IP match"
    end

    attribute :classifications, {:array, :string} do
      default []
      public? true
      description "Classification tags to apply"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
