# Executed only by the declared Bazel schema-generation action with pinned
# AshPostgres, OTP and Elixir. This domain scopes codegen to the new inbox.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.AlertEvaluationSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Observability.AlertEvaluationLane
    resource ServiceRadar.Observability.AlertEvaluationWork
    resource ServiceRadar.Observability.AlertEvaluationReceipt
  end
end

[lane_output, work_output, receipt_output, migration_output] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "alert_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.AlertEvaluationSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_alert_evaluation_inbox",
    no_shell?: true,
    quiet: true,
    format: false
  )

  Enum.each(
    [
      {"alert_evaluation_lanes", lane_output},
      {"alert_evaluation_work", work_output},
      {"alert_evaluation_receipts", receipt_output}
    ],
    fn {table, output} ->
      [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
      File.mkdir_p!(Path.dirname(output))
      File.cp!(snapshot, output)
    end
  )

  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_alert_evaluation_inbox.exs"))
  rollback_guard = ~S'''
  def down do
    execute("""
    DO $$ BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended('alert-evaluation:admission:v1', 0));
      IF EXISTS (SELECT 1 FROM platform.alert_evaluation_work) THEN
        RAISE EXCEPTION 'Drain accepted alert evaluation work before rollback';
      END IF;
    END; $$
    """)
  '''

  source = migration |> File.read!() |> String.replace("def down do", rollback_guard)
  File.write!(migration_output, [Code.format_string!(source), "\n"])
after
  File.rm_rf!(scratch)
end
