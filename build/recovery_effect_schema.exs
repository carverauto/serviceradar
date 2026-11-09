# Generate only the recovery consumer effect resources with pinned AshPostgres.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.RecoveryEffectSchema do
  use Ash.Domain, validate_config_inclusion?: false
  resources do
    resource ServiceRadar.Edge.RecoveryLossSpan
    resource ServiceRadar.Edge.RecoveryLossTransition
    resource ServiceRadar.Edge.RecoveryRangeLoss
    resource ServiceRadar.Edge.RecoveryGenerationFence
    resource ServiceRadar.Edge.RecoveryRetryIntent
  end
end

[span_output, transition_output, range_output, fence_output, retry_output, migration_output] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "recovery_effect_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.RecoveryEffectSchema,
    snapshot_path: scratch, migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_edge_recovery_effects", no_shell?: true, quiet: true, format: false)

  for {table, output} <- [
    {"edge_recovery_loss_spans", span_output}, {"edge_recovery_loss_transitions", transition_output},
    {"edge_recovery_range_losses", range_output}, {"edge_recovery_generation_fences", fence_output},
    {"edge_recovery_retry_intents", retry_output}
  ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end
  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_edge_recovery_effects.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
