defmodule ServiceRadar.Repo.Migrations.RemoveSyncServices do
  @moduledoc """
  Removes sync_services and sync_service_id now that sync is agent-embedded.
  """

  use Ecto.Migration

  def up do
    drop constraint(:integration_sources, "integration_sources_sync_service_id_fkey")

    alter table(:integration_sources) do
      remove :sync_service_id
    end

    drop_if_exists unique_index(:sync_services, [:tenant_id, :component_id],
                     name: "sync_services_unique_component_id_index"
                   )

    drop_if_exists unique_index(:sync_services, [:tenant_id],
                     name: "sync_services_unique_platform_sync_index"
                   )

    drop table(:sync_services)
  end

  def down do
    create table(:sync_services, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :service_type, :text, null: false
      add :endpoint, :text
      add :status, :text, null: false, default: "offline"
      add :is_platform_sync, :boolean, null: false, default: false
      add :capabilities, {:array, :text}, default: []
      add :last_heartbeat_at, :utc_datetime
      add :tenant_id, :uuid, null: false
      add :component_id, :text, null: false

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:sync_services, [:tenant_id],
             name: "sync_services_unique_platform_sync_index",
             where: "(is_platform_sync = true)"
           )

    create unique_index(:sync_services, [:tenant_id, :component_id],
             name: "sync_services_unique_component_id_index"
           )

    alter table(:integration_sources) do
      add :sync_service_id,
          references(:sync_services,
            column: :id,
            name: "integration_sources_sync_service_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end
  end
end
