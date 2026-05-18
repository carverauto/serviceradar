defmodule ServiceRadar.Repo.Migrations.EnforceSingleRunningArmisNorthboundRun do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @index_name "integration_update_runs_one_running_per_source_uidx"

  def up do
    execute("""
    WITH ranked AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY integration_source_id, run_type
          ORDER BY started_at DESC NULLS LAST, inserted_at DESC NULLS LAST, id DESC
        ) AS rank
      FROM #{@prefix}.integration_update_runs
      WHERE status = 'running'
        AND run_type = 'armis_northbound'
    )
    UPDATE #{@prefix}.integration_update_runs AS runs
    SET
      status = 'timeout',
      finished_at = COALESCE(runs.finished_at, now()),
      error_message = COALESCE(
        runs.error_message,
        'Marked timed out while enforcing single active Armis northbound run'
      ),
      metadata = jsonb_strip_nulls(
        COALESCE(runs.metadata, '{}'::jsonb) ||
        jsonb_build_object(
          'reconciled', true,
          'reason', 'superseded_duplicate_running_run'
        )
      ),
      updated_at = now()
    FROM ranked
    WHERE runs.id = ranked.id
      AND ranked.rank > 1
    """)

    create unique_index(:integration_update_runs, [:integration_source_id, :run_type],
             prefix: @prefix,
             name: @index_name,
             where: "status = 'running'"
           )
  end

  def down do
    drop_if_exists index(:integration_update_runs, [:integration_source_id, :run_type],
                     prefix: @prefix,
                     name: @index_name
                   )
  end
end
