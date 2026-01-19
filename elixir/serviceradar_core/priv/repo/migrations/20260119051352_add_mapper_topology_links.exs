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
      PERFORM ag_catalog.create_graph('serviceradar_topology');
    EXCEPTION
      WHEN duplicate_object THEN
        NULL;
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
