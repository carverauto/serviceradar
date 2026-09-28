defmodule ServiceRadar.Repo.Migrations.WidenNetflowInterfaceCacheSpeed do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:netflow_interface_cache, prefix: "platform") do
      modify(:if_speed_bps, :bigint)
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "Cannot roll back netflow_interface_cache.if_speed_bps to integer: stored speeds may exceed the signed 32-bit range; leave the bigint column intact"
  end
end
