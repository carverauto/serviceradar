defmodule ServiceRadar.Repo.Migrations.AddUniqueSweepHostResultsExecutionIp do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM sweep_host_results
    WHERE id IN (
      SELECT id
      FROM (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY execution_id, ip
                 ORDER BY inserted_at DESC, id DESC
               ) AS rn
        FROM sweep_host_results
      ) dedupe
      WHERE dedupe.rn > 1
    )
    """)

    create unique_index(:sweep_host_results, [:execution_id, :ip],
             name: "sweep_host_results_execution_ip_uidx"
           )
  end

  def down do
    drop_if_exists index(:sweep_host_results, [:execution_id, :ip],
                     name: "sweep_host_results_execution_ip_uidx"
                   )
  end
end
