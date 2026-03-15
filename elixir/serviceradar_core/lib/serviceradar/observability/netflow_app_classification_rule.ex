defmodule ServiceRadar.Observability.NetflowAppClassificationRule do
  @moduledoc """
  Admin-managed override rules for NetFlow application classification.

  SRQL derives an `app` label for flows using a baseline port mapping and then applies
  the highest-priority matching override rule (if any).
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Types.Cidr

  @netflow_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                         permission: "settings.netflow.manage"}
  @classification_rule_fields [
    :partition,
    :enabled,
    :priority,
    :protocol_num,
    :dst_port,
    :src_port,
    :dst_cidr,
    :src_cidr,
    :app_label,
    :notes
  ]

  postgres do
    table "netflow_app_classification_rules"
    repo ServiceRadar.Repo
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @classification_rule_fields
    end

    update :update do
      accept @classification_rule_fields
    end

    read :list do
      primary? true
      pagination keyset?: true, default_limit: 200
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:create) do
      authorize_if @netflow_manage_check
    end

    policy action_type(:update) do
      authorize_if @netflow_manage_check
    end

    policy action_type(:destroy) do
      authorize_if @netflow_manage_check
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end

  validations do
    validate present(:app_label)
  end

  attributes do
    uuid_primary_key :id

    attribute :partition, :string do
      public? true
      allow_nil? true
      description "Optional partition scope (matches ocsf_network_activity.partition)"
    end

    attribute :enabled, :boolean do
      public? true
      allow_nil? false
      default true
    end

    attribute :priority, :integer do
      public? true
      allow_nil? false
      default 0
      description "Higher priority overrides win when multiple rules match"
    end

    attribute :protocol_num, :integer do
      public? true
      allow_nil? true
      description "Optional protocol number match (e.g., 6 TCP, 17 UDP)"
    end

    attribute :dst_port, :integer do
      public? true
      allow_nil? true
      description "Optional destination port match"
    end

    attribute :src_port, :integer do
      public? true
      allow_nil? true
      description "Optional source port match"
    end

    attribute :dst_cidr, Cidr do
      public? true
      allow_nil? true
      description "Optional destination CIDR match"
    end

    attribute :src_cidr, Cidr do
      public? true
      allow_nil? true
      description "Optional source CIDR match"
    end

    attribute :app_label, :string do
      public? true
      allow_nil? false
      description "Application label to apply when this rule matches"
    end

    attribute :notes, :string do
      public? true
      allow_nil? true
    end

    timestamps()
  end
end
