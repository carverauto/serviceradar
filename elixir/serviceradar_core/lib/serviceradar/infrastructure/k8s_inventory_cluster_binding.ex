defmodule ServiceRadar.Infrastructure.K8sInventoryClusterBinding do
  @moduledoc """
  Operator-owned authorization binding for agent-forwarded Kubernetes inventory.

  Snapshot content and agent metadata cannot create or update this resource.
  """

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  alias ServiceRadar.Infrastructure.Changes.StampK8sBindingActor

  postgres do
    table "k8s_inventory_cluster_bindings"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :agent, on_delete: :restrict
    end
  end

  json_api do
    type "k8s_inventory_cluster_binding"

    routes do
      base "/k8s-inventory-cluster-bindings"
      index :read
      get :read
      post :create
      patch :update
      delete :destroy
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:cluster_id, :agent_id, :partition_id]
      change StampK8sBindingActor
    end

    update :update do
      accept [:agent_id, :partition_id]
      require_atomic? false
      change StampK8sBindingActor
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    admin_action_type([:read, :create, :update, :destroy])
  end

  attributes do
    attribute :cluster_id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :partition_id, :string do
      allow_nil? false
      public? true
    end

    attribute :changed_by, :string do
      allow_nil? false
      public? true
      default "system"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_id
      destination_attribute :uid
      define_attribute? false
      allow_nil? false
    end
  end
end
