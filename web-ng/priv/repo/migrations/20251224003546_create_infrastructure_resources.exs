defmodule ServiceRadarWebNG.Repo.Migrations.CreateInfrastructureResources do
  @moduledoc """
  Creates partitions and checkers tables, and adds partition_id to pollers.

  This migration adds:
  - partitions table for network partition management
  - checkers table for service check configuration
  - partition_id column on pollers for partition assignment
  - Foreign key relationships
  """

  use Ecto.Migration

  def up do
    # Create partitions table
    create table(:partitions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :cidr_ranges, {:array, :text}, default: []
      add :default_gateway, :text
      add :dns_servers, {:array, :text}, default: []
      add :site, :text
      add :region, :text
      add :environment, :text, default: "production"
      add :connectivity_type, :text, default: "direct"
      add :proxy_endpoint, :text
      add :metadata, :map, default: %{}
      add :created_at, :utc_datetime
      add :updated_at, :utc_datetime

      add :tenant_id, references(:tenants, column: :id, type: :uuid, on_delete: :delete_all),
        null: false
    end

    create unique_index(:partitions, [:tenant_id, :slug],
             name: "partitions_unique_slug_per_tenant_index"
           )

    create index(:partitions, [:tenant_id])

    # Add partition_id to pollers
    alter table(:pollers) do
      add :partition_id, references(:partitions, column: :id, type: :uuid, on_delete: :nilify_all)
    end

    create index(:pollers, [:partition_id])

    # Create checkers table
    create table(:checkers, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :type, :text, null: false
      add :description, :text
      add :enabled, :boolean, default: true
      add :config, :map, default: %{}
      add :interval_seconds, :bigint, default: 60
      add :timeout_seconds, :bigint, default: 30
      add :retries, :bigint, default: 3
      add :target_type, :text, default: "agent"
      add :target_filter, :map, default: %{}

      add :agent_uid,
          references(:ocsf_agents,
            column: :uid,
            name: "checkers_agent_uid_fkey",
            type: :text,
            on_delete: :nilify_all
          )

      add :created_at, :utc_datetime
      add :updated_at, :utc_datetime

      add :tenant_id, references(:tenants, column: :id, type: :uuid, on_delete: :delete_all),
        null: false
    end

    create index(:checkers, [:tenant_id])
    create index(:checkers, [:agent_uid])
    create index(:checkers, [:type])
  end

  def down do
    drop constraint(:checkers, "checkers_agent_uid_fkey")
    drop table(:checkers)

    alter table(:pollers) do
      remove :partition_id
    end

    drop_if_exists unique_index(:partitions, [:tenant_id, :slug],
                     name: "partitions_unique_slug_per_tenant_index"
                   )

    drop table(:partitions)
  end
end
