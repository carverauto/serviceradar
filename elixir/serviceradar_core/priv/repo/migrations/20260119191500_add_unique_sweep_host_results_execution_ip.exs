defmodule ServiceRadar.Repo.Migrations.AddUniqueSweepHostResultsExecutionIp do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pg_tables
        WHERE schemaname = '#{prefix()}'
          AND tablename = 'sweep_host_results'
      ) THEN
        DELETE FROM #{prefix()}.sweep_host_results
        WHERE id IN (
          SELECT id
          FROM (
            SELECT id,
                   ROW_NUMBER() OVER (
                     PARTITION BY execution_id, ip
                     ORDER BY inserted_at DESC, id DESC
                   ) AS rn
            FROM #{prefix()}.sweep_host_results
          ) dedupe
          WHERE dedupe.rn > 1
        );
      END IF;
    END
    $$;
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
