Mix.start()
Mix.env(:test)

tables = ~w(topology_world_head topology_world_layouts topology_world_positions topology_world_relations)
outputs = System.argv()

if length(outputs) != length(tables), do: raise("Expected one declared output for each world resource")

scratch = Path.join(Path.dirname(hd(outputs)), "snapshot_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.NetworkDiscovery,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    snapshots_only: true,
    no_shell?: true,
    quiet: true,
    format: false
  )

  Enum.zip_with(tables, outputs, fn table, output ->
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.mkdir_p!(Path.dirname(output))
    File.cp!(snapshot, output)
  end)
after
  File.rm_rf!(scratch)
end
