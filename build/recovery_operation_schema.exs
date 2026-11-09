# Generate recovery control storage with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.RecoveryOperationSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Edge.RecoveryRegistration
    resource ServiceRadar.Edge.RecoveryReceivedPage
  end
end

[registration_output, page_output, migration_output] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "recovery_operation_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.RecoveryOperationSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_edge_recovery_operations",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"edge_recovery_registrations", registration_output},
        {"edge_recovery_received_pages", page_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_edge_recovery_operations.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
