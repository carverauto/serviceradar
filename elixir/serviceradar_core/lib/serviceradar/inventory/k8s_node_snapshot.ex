defmodule ServiceRadar.Inventory.K8sNodeSnapshot do
  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "k8s_node_snapshots"
    schema "platform"
    repo ServiceRadar.Repo
    migrate? false
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :cluster_id, :string do
      primary_key? true
      allow_nil? false
    end

    attribute :snapshot_at, :utc_datetime_usec do
      allow_nil? false
    end
  end
end
