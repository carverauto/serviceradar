defmodule ServiceRadar.Repo.Migrations.AddNetflowInterfaceExporterCacheTables do
  @moduledoc """
  Adds bounded cache tables for NetFlow exporter/interface metadata.

  These tables are used for SRQL dimensions like `exporter_name`, `in_if_name`, `out_if_name`,
  and to support units like percent-of-capacity in follow-up changes.
  """

  use Ecto.Migration

  def up do
    create table(:netflow_exporter_cache, primary_key: false, prefix: "platform") do
      add :sampler_address, :text, primary_key: true
      add :exporter_name, :text
      add :device_uid, :text
      add :refreshed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:netflow_exporter_cache, [:device_uid], prefix: "platform")
    create index(:netflow_exporter_cache, [:refreshed_at], prefix: "platform")

    create table(:netflow_interface_cache, primary_key: false, prefix: "platform") do
      add :sampler_address, :text, primary_key: true
      add :if_index, :integer, primary_key: true
      add :device_uid, :text
      add :if_name, :text
      add :if_description, :text
      # Keep consistent with existing interface inventory field type (`discovered_interfaces.speed_bps`).
      add :if_speed_bps, :integer
      add :boundary, :text
      add :refreshed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:netflow_interface_cache, [:device_uid], prefix: "platform")
    create index(:netflow_interface_cache, [:sampler_address], prefix: "platform")
    create index(:netflow_interface_cache, [:refreshed_at], prefix: "platform")
  end

  def down do
    drop table(:netflow_interface_cache, prefix: "platform")
    drop table(:netflow_exporter_cache, prefix: "platform")
  end
end
