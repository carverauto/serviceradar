# Generate the Stage B camera recording catalog and gap tables, indexes, restrictive FKs,
# check constraints, and terminal-state / append-only triggers with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraRecordingCatalogSchema do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.RecordingCatalogEntry
    resource ServiceRadar.Camera.RecordingGap
  end
end

[catalog_output, gap_output, migration_output] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "camera_recording_catalog_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraRecordingCatalogSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_recording_catalog_and_gaps",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"camera_recording_catalog", catalog_output},
        {"camera_recording_gaps", gap_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_camera_recording_catalog_and_gaps.exs"))

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
