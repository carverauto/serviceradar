defmodule ServiceRadar.Repo.Migrations.AddSweepHostResultCoverage do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:sweep_host_results, prefix: @prefix) do
      add :scanned_ports, {:array, :bigint}, null: false, default: []
      add :agent_id, :text
      add :sweep_group_id, :uuid
    end
  end

  def down do
    alter table(:sweep_host_results, prefix: @prefix) do
      remove :sweep_group_id
      remove :agent_id
      remove :scanned_ports
    end
  end
end
