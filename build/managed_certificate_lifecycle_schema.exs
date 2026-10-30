Mix.start()
Mix.env(:test)

defmodule ServiceRadar.ManagedCertificateLifecycleSchema do
  use Ash.Domain, validate_config_inclusion?: false
  resources do
    resource ServiceRadar.Edge.ManagedComponent
    resource ServiceRadar.Edge.ManagedCertificateOperation
  end
end

[component_output, operation_output, migration_output, baseline] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "managed_certificate_lifecycle_schema_scratch")
File.mkdir_p!(Path.join(scratch, "repo/platform.managed_components"))
File.cp!(baseline, Path.join(scratch, "repo/platform.managed_components/20261030193000.json"))
try do
  current = ServiceRadar.ManagedCertificateLifecycleSchema
    |> AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.Repo)
    |> Enum.find(&(&1.table == "managed_components"))
  unless AshPostgres.MigrationGenerator.get_existing_snapshot(current, %AshPostgres.MigrationGenerator{snapshot_path: scratch}),
    do: raise("managed component baseline was not found")

  AshPostgres.MigrationGenerator.generate(ServiceRadar.ManagedCertificateLifecycleSchema,
    snapshot_path: scratch, migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_managed_certificate_lifecycle", no_shell?: false, quiet: true, format: false)
  for {table, output} <- [{"managed_components", component_output}, {"managed_certificate_operations", operation_output}] do
    snapshot = Path.join(scratch, "repo/platform.#{table}/*.json") |> Path.wildcard() |> Enum.sort() |> List.last()
    File.cp!(snapshot, output)
  end
  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_managed_certificate_lifecycle.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
