defmodule ServiceRadar.Repo.Migrations.AddDeviceAgentAvailabilityAgentUpdatedIndex do
  @moduledoc """
  Serves the composite-check incremental dirty read:
  `WHERE agent_id = ANY($1) AND updated_at > $2`.

  `device_agent_availability` is upserted by every sweep chunk, so the index is
  built `CONCURRENTLY` to avoid blocking those writes. That cannot run inside a
  transaction, hence a migration of its own with the DDL transaction and
  migration lock disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:device_agent_availability, [:agent_id, :updated_at],
        prefix: "platform",
        name: "device_agent_availability_agent_updated_idx",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:device_agent_availability, [:agent_id, :updated_at],
        prefix: "platform",
        name: "device_agent_availability_agent_updated_idx",
        concurrently: true
      )
    )
  end
end
