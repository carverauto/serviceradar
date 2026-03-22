defmodule ServiceRadar.Repo.Migrations.AddMapperTopologyLinks do
  @moduledoc """
  Adds mapper topology link storage and initializes the AGE graph.
  """

  use Ecto.Migration

  def up do
    create table(:mapper_topology_links, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :timestamp, :utc_datetime, null: false
      add :agent_id, :text
      add :gateway_id, :text
      add :partition, :text, default: "default"
      add :protocol, :text
      add :local_device_ip, :text
      add :local_device_id, :text
      add :local_if_index, :bigint
      add :local_if_name, :text
      add :neighbor_device_id, :text
      add :neighbor_chassis_id, :text
      add :neighbor_port_id, :text
      add :neighbor_port_descr, :text
      add :neighbor_system_name, :text
      add :neighbor_mgmt_addr, :text
      add :metadata, :map, default: %{}
      add :created_at, :utc_datetime
    end

    execute("""
    DO $$
    BEGIN
      BEGIN
        EXECUTE 'LOAD ''age''';
      EXCEPTION
        WHEN insufficient_privilege THEN
          IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
            RAISE NOTICE 'Skipping LOAD ''age'' due to insufficient privilege; AGE extension already exists.';
          ELSE
            RAISE;
          END IF;
      END;
    END
    $$;
    """)

    execute("""
    DO $$
    DECLARE
      graph_exists boolean;
      attempts integer := 0;
    BEGIN
      PERFORM set_config('search_path', 'ag_catalog,"$user",public', true);

      SELECT EXISTS(
        SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'serviceradar_topology'
      ) INTO graph_exists;

      IF NOT graph_exists THEN
        WHILE attempts < 3 AND NOT graph_exists LOOP
          attempts := attempts + 1;

          BEGIN
            PERFORM ag_catalog.create_graph('serviceradar_topology');
          EXCEPTION
            WHEN duplicate_object OR duplicate_schema OR invalid_schema_name THEN
              NULL;
            WHEN undefined_object THEN
              IF attempts >= 3 THEN
                RAISE;
              END IF;

              PERFORM pg_sleep(0.2);
          END;

          SELECT EXISTS(
            SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'serviceradar_topology'
          ) INTO graph_exists;
        END LOOP;
      END IF;

      IF NOT graph_exists THEN
        RAISE EXCEPTION 'AGE graph "%" is missing after migration', 'serviceradar_topology';
      END IF;
    END
    $$;
    """)
  end

  def down do
    drop table(:mapper_topology_links)

    execute("""
    DO $$
    BEGIN
      PERFORM ag_catalog.drop_graph('serviceradar_topology', true);
    EXCEPTION
      WHEN undefined_object THEN
        NULL;
    END
    $$;
    """)
  end
end
