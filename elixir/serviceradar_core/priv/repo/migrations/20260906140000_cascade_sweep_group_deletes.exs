defmodule ServiceRadar.Repo.Migrations.CascadeSweepGroupDeletes do
  @moduledoc """
  Let an operator delete a sweep group that has already run.

  `sweep_group_executions.sweep_group_id` and `sweep_host_results.execution_id`
  were created without an `ON DELETE` action, so PostgreSQL defaulted both to
  `NO ACTION`. A single execution row therefore pinned its group permanently:
  every group that has ever run refused deletion with a `23503` violation,
  which the settings UI could only report as a generic failure.

  Both levels have to cascade, not just the first. Cascading the group to its
  executions makes PostgreSQL delete those execution rows, and that delete is
  itself checked against `sweep_host_results.execution_id` -- so leaving the
  second constraint alone would move the violation one level down rather than
  remove it.

  The deletion contract is defined in `openspec/specs/sweep-jobs/spec.md`.
  Scheduled retention has separate safeguards documented in
  `ServiceRadar.SweepJobs.SweepDataCleanupWorker`.
  The audit trail is unaffected -- `sweep_group_execution_versions` is
  append-only and holds no foreign key into either table, so its rows survive
  the cascade.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    drop constraint(:sweep_group_executions, "sweep_group_executions_sweep_group_id_fkey",
           prefix: @prefix
         )

    alter table(:sweep_group_executions, prefix: @prefix) do
      modify :sweep_group_id,
             references(:sweep_groups,
               column: :id,
               name: "sweep_group_executions_sweep_group_id_fkey",
               type: :uuid,
               prefix: @prefix,
               on_delete: :delete_all
             )
    end

    drop constraint(:sweep_host_results, "sweep_host_results_execution_id_fkey", prefix: @prefix)

    alter table(:sweep_host_results, prefix: @prefix) do
      modify :execution_id,
             references(:sweep_group_executions,
               column: :id,
               name: "sweep_host_results_execution_id_fkey",
               type: :uuid,
               prefix: @prefix,
               on_delete: :delete_all
             )
    end
  end

  def down do
    drop constraint(:sweep_host_results, "sweep_host_results_execution_id_fkey", prefix: @prefix)

    alter table(:sweep_host_results, prefix: @prefix) do
      modify :execution_id,
             references(:sweep_group_executions,
               column: :id,
               name: "sweep_host_results_execution_id_fkey",
               type: :uuid,
               prefix: @prefix
             )
    end

    drop constraint(:sweep_group_executions, "sweep_group_executions_sweep_group_id_fkey",
           prefix: @prefix
         )

    alter table(:sweep_group_executions, prefix: @prefix) do
      modify :sweep_group_id,
             references(:sweep_groups,
               column: :id,
               name: "sweep_group_executions_sweep_group_id_fkey",
               type: :uuid,
               prefix: @prefix
             )
    end
  end
end
