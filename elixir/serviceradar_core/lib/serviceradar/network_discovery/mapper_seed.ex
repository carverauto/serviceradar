defmodule ServiceRadar.NetworkDiscovery.MapperSeed do
  @moduledoc """
  Seed targets for mapper discovery jobs.
  """

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mapper_job_seeds"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:mapper_job_id], name: "mapper_job_seeds_job_idx"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:seed, :mapper_job_id]
    end

    update :update do
      accept [:seed]
    end

    read :by_job do
      argument :mapper_job_id, :uuid, allow_nil?: false
      filter expr(mapper_job_id == ^arg(:mapper_job_id))
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
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :seed, :string do
      allow_nil? false
      public? true
      description "Seed target (IP/CIDR/hostname)"
    end

    attribute :mapper_job_id, :uuid do
      allow_nil? false
      public? true
      description "Parent mapper job ID"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :mapper_job, ServiceRadar.NetworkDiscovery.MapperJob do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :mapper_job_id
      destination_attribute :id
    end
  end

  identities do
    identity :unique_seed_per_job, [:mapper_job_id, :seed]
  end
end
