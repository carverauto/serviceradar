# Generate the incremental E1 retention settings columns, restrictive FK, and SQL check
# constraints on RecordingArchiveSettings against its committed Ash baselines.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraNvrRetentionSettingsSchema do
  @moduledoc false
  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Camera.RecordingArchiveSettings
  end
end

[
  settings_output,
  migration_output,
  settings_baseline,
  versions_baseline
] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "camera_nvr_retention_settings_scratch")

for {table, baseline} <- [
      {"camera_recording_archive_settings", settings_baseline},
      {"camera_recording_archive_settings_versions", versions_baseline}
    ] do
  dir = Path.join(scratch, "repo/platform.#{table}")
  File.mkdir_p!(dir)
  File.cp!(baseline, Path.join(dir, Path.basename(baseline)))
end

try do
  current_by_table =
    ServiceRadar.CameraNvrRetentionSettingsSchema
    |> AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.Repo)
    |> Map.new(&{&1.table, &1})

  for table <- [
        "camera_recording_archive_settings",
        "camera_recording_archive_settings_versions"
      ] do
    current = Map.fetch!(current_by_table, table)

    previous =
      AshPostgres.MigrationGenerator.get_existing_snapshot(
        current,
        %AshPostgres.MigrationGenerator{snapshot_path: scratch}
      )

    if !previous, do: raise("#{table} baseline snapshot was not found")
  end

  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraNvrRetentionSettingsSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_nvr_retention_settings",
    # The pinned generator's no_shell mode ignores on-disk baselines.
    no_shell?: false,
    quiet: true,
    format: false
  )

  snapshots =
    scratch
    |> Path.join("repo/platform.camera_recording_archive_settings/*.json")
    |> Path.wildcard()
    |> Enum.sort()

  if length(snapshots) < 2 do
    raise(
      "expected new snapshot for camera_recording_archive_settings, got: #{inspect(snapshots)}"
    )
  end

  File.cp!(List.last(snapshots), settings_output)

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_camera_nvr_retention_settings.exs"))

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
