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

    create index(:sweep_host_results, [:sweep_group_id, :inserted_at],
             prefix: @prefix,
             name: "sweep_host_results_group_inserted_idx",
             where: "sweep_group_id IS NOT NULL"
           )

    create index(:sweep_host_results, [:agent_id, :inserted_at],
             prefix: @prefix,
             name: "sweep_host_results_agent_inserted_idx",
             where: "agent_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:sweep_host_results, [:agent_id, :inserted_at],
                     prefix: @prefix,
                     name: "sweep_host_results_agent_inserted_idx"
                   )

    drop_if_exists index(:sweep_host_results, [:sweep_group_id, :inserted_at],
                     prefix: @prefix,
                     name: "sweep_host_results_group_inserted_idx"
                   )

    alter table(:sweep_host_results, prefix: @prefix) do
      remove :sweep_group_id
      remove :agent_id
      remove :scanned_ports
    end
  end
end
