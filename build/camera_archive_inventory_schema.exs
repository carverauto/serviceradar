# Generate only the publication inventory index against its committed Ash baseline.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraArchiveInventorySchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.RecordingBlock
  end
end

[snapshot_output, migration_output, baseline] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "camera_archive_inventory_scratch")
snapshots = Path.join(scratch, "repo/platform.camera_recording_blocks")
File.mkdir_p!(snapshots)
File.cp!(baseline, Path.join(snapshots, Path.basename(baseline)))

try do
  [current] = AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.CameraArchiveInventorySchema, ServiceRadar.Repo)
  previous = AshPostgres.MigrationGenerator.get_existing_snapshot(current, %AshPostgres.MigrationGenerator{snapshot_path: scratch})
  unless previous, do: raise("camera recording block baseline was not found")

  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraArchiveInventorySchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "index_camera_archive_inventory",
    # The pinned generator's no_shell mode ignores on-disk baselines.
    no_shell?: false,
    quiet: true,
    format: false
  )

  snapshot = snapshots |> Path.join("*.json") |> Path.wildcard() |> Enum.sort() |> List.last()
  File.cp!(snapshot, snapshot_output)
  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_index_camera_archive_inventory.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
