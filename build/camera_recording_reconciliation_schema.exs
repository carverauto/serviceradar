# Generate the Stage R incremental reservation resolution columns, filtered index, and
# SQL check constraint on RecordingBlock plus quarantine evidence and operator disposition
# tracking on RecordingCatalogEntry against their committed Ash baselines.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraRecordingReconciliationSchema do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.RecordingBlock
    resource ServiceRadar.Camera.RecordingCatalogEntry
  end
end

[
  block_output,
  catalog_output,
  migration_output,
  block_baseline,
  catalog_baseline
] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "camera_recording_reconciliation_scratch")

for {table, baseline} <- [
      {"camera_recording_blocks", block_baseline},
      {"camera_recording_catalog", catalog_baseline}
    ] do
  dir = Path.join(scratch, "repo/platform.#{table}")
  File.mkdir_p!(dir)
  File.cp!(baseline, Path.join(dir, Path.basename(baseline)))
end

try do
  current_by_table =
    ServiceRadar.CameraRecordingReconciliationSchema
    |> AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.Repo)
    |> Map.new(&{&1.table, &1})

  for table <- ["camera_recording_blocks", "camera_recording_catalog"] do
    current = Map.fetch!(current_by_table, table)

    previous =
      AshPostgres.MigrationGenerator.get_existing_snapshot(
        current,
        %AshPostgres.MigrationGenerator{snapshot_path: scratch}
      )

    if !previous, do: raise("#{table} baseline snapshot was not found")
  end

  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraRecordingReconciliationSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_recording_reconciliation",
    # The pinned generator's no_shell mode ignores on-disk baselines.
    no_shell?: false,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"camera_recording_blocks", block_output},
        {"camera_recording_catalog", catalog_output}
      ] do
    snapshots =
      scratch
      |> Path.join("repo/platform.#{table}/*.json")
      |> Path.wildcard()
      |> Enum.sort()

    if length(snapshots) < 2 do
      raise("expected new snapshot for #{table}, got: #{inspect(snapshots)}")
    end

    File.cp!(List.last(snapshots), output)
  end

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_camera_recording_reconciliation.exs"))

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
