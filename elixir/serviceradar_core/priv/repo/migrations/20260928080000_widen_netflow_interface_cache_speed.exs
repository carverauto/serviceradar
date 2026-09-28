defmodule ServiceRadar.Repo.Migrations.WidenNetflowInterfaceCacheSpeed do
  use Ecto.Migration

  def change do
    alter table(:netflow_interface_cache, prefix: "platform") do
      modify :if_speed_bps, :bigint, from: :integer
    end
  end
end
