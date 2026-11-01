Mix.start()
Mix.env(:test)

defmodule ServiceRadar.ManagedComponentPermissionsSchema do
  use Ash.Domain, validate_config_inclusion?: false
  resources do
    resource ServiceRadar.Edge.ManagedComponent
  end
end

[snapshot_output, migration_output, baseline] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "managed_component_permissions_schema_scratch")
File.mkdir_p!(Path.join(scratch, "repo/platform.managed_components"))
File.cp!(baseline, Path.join(scratch, "repo/platform.managed_components/20261030203000.json"))
try do
  [current] = AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.ManagedComponentPermissionsSchema, ServiceRadar.Repo)
  unless AshPostgres.MigrationGenerator.get_existing_snapshot(current, %AshPostgres.MigrationGenerator{snapshot_path: scratch}),
    do: raise("managed component baseline was not found")

  AshPostgres.MigrationGenerator.generate(ServiceRadar.ManagedComponentPermissionsSchema,
    snapshot_path: scratch, migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_managed_component_permissions", no_shell?: false, quiet: true, format: false)
  snapshot = Path.join(scratch, "repo/platform.managed_components/*.json") |> Path.wildcard() |> Enum.sort() |> List.last()
  File.cp!(snapshot, snapshot_output)
  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_managed_component_permissions.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
