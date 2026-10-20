defmodule ServiceRadar.Repo.Migrations.IndexDeviceAgentAvailabilityCheckedAt do
  @moduledoc """
  Serves the availability expiry job of `add-merged-device-availability` (stage b):
  per freshness window it reads the per-agent results whose `checked_at` fell past the
  window since its last run, `WHERE checked_at > $1 AND checked_at <= $2`.

  `device_agent_availability` is upserted by every sweep chunk, so the index is built
  `CONCURRENTLY` so those writes are never blocked. That cannot run inside a
  transaction, hence a migration of its own with the DDL transaction and migration
  lock disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:device_agent_availability, [:checked_at],
        prefix: "platform",
        name: "device_agent_availability_checked_at_idx",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:device_agent_availability, [:checked_at],
        prefix: "platform",
        name: "device_agent_availability_checked_at_idx",
        concurrently: true
      )
    )
  end
end
