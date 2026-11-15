# Generate the Stage A1 NVR operator settings tables and incremental camera archive/block updates
# against their committed Ash baselines using the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraNvrOperatorSettingsSchema do
  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Camera.ArchiveBinding
    resource ServiceRadar.Camera.RecordingBlock
    resource ServiceRadar.Camera.RecordingArchiveSettings
    resource ServiceRadar.Camera.NVRArchiveReceipt
    resource ServiceRadar.Camera.RecordingOperation
  end
end

[
  binding_output,
  block_output,
  settings_output,
  settings_version_output,
  receipt_output,
  operation_output,
  migration_output,
  binding_baseline,
  block_baseline
] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "camera_nvr_operator_settings_scratch")

for {table, baseline} <- [
      {"camera_archive_bindings", binding_baseline},
      {"camera_recording_blocks", block_baseline}
    ] do
  dir = Path.join(scratch, "repo/platform.#{table}")
  File.mkdir_p!(dir)
  File.cp!(baseline, Path.join(dir, Path.basename(baseline)))
end

try do
  current_by_table =
    ServiceRadar.CameraNvrOperatorSettingsSchema
    |> AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.Repo)
    |> Map.new(&{&1.table, &1})

  for table <- ["camera_archive_bindings", "camera_recording_blocks"] do
    current = Map.fetch!(current_by_table, table)

    previous =
      AshPostgres.MigrationGenerator.get_existing_snapshot(
        current,
        %AshPostgres.MigrationGenerator{snapshot_path: scratch}
      )

    unless previous, do: raise("#{table} baseline snapshot was not found")
  end

  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraNvrOperatorSettingsSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_nvr_operator_settings",
    # The pinned generator's no_shell mode ignores on-disk baselines.
    no_shell?: false,
    quiet: true,
    format: false
  )

  outputs = [
    {"camera_archive_bindings", binding_output},
    {"camera_recording_blocks", block_output},
    {"camera_recording_archive_settings", settings_output},
    {"camera_recording_archive_settings_versions", settings_version_output},
    {"camera_nvr_archive_receipts", receipt_output},
    {"camera_recording_operations", operation_output}
  ]

  for {table, output} <- outputs do
    snapshot =
      scratch
      |> Path.join("repo/platform.#{table}/*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> List.last()

    unless snapshot, do: raise("generated snapshot missing for #{table}")
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_camera_nvr_operator_settings.exs"))

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
