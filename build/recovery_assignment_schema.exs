# Generate the historical mapping ledger with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.RecoveryAssignmentSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Edge.RecoveryAssignmentKey
    resource ServiceRadar.Edge.RecoveryAssignmentIssuance
    resource ServiceRadar.Edge.RecoveryAssignmentCandidate
    resource ServiceRadar.Edge.RecoveryAssignmentResolution
  end
end

[key_output, issuance_output, candidate_output, resolution_output, migration_output] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "recovery_assignment_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.RecoveryAssignmentSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_edge_recovery_assignments",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"edge_recovery_assignment_keys", key_output},
        {"edge_recovery_assignment_issuances", issuance_output},
        {"edge_recovery_assignment_candidates", candidate_output},
        {"edge_recovery_assignment_resolutions", resolution_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_edge_recovery_assignments.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
