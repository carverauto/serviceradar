# Generate the archive destination and incremental block FK from the committed block baseline.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraArchiveBindingSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.ArchiveBinding
    resource ServiceRadar.Camera.RecordingBlock
  end
end

[binding_output, block_output, migration_output, baseline] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "camera_archive_binding_scratch")
block_snapshots = Path.join(scratch, "repo/platform.camera_recording_blocks")
File.mkdir_p!(block_snapshots)
File.cp!(baseline, Path.join(block_snapshots, Path.basename(baseline)))

try do
  current =
    ServiceRadar.CameraArchiveBindingSchema
    |> AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.Repo)
    |> Enum.find(&(&1.table == "camera_recording_blocks"))

  previous = AshPostgres.MigrationGenerator.get_existing_snapshot(current, %AshPostgres.MigrationGenerator{snapshot_path: scratch})
  unless previous, do: raise("camera block baseline was not found")

  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraArchiveBindingSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_archive_bindings",
    no_shell?: false,
    quiet: true,
    format: false
  )

  for {table, output} <- [{"camera_archive_bindings", binding_output}, {"camera_recording_blocks", block_output}] do
    snapshot = scratch |> Path.join("repo/platform.#{table}/*.json") |> Path.wildcard() |> Enum.sort() |> List.last()
    File.cp!(snapshot, output)
  end

  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_camera_archive_bindings.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
