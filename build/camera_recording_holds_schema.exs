# Generate the Stage C camera recording holds (with AshPaperTrail versions) and append-only
# recording dispositions tables, indexes, restrictive FKs, check constraints, and
# BEFORE UPDATE OR DELETE trigger with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraRecordingHoldsSchema do
  @moduledoc false
  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Camera.RecordingHold
    resource ServiceRadar.Camera.RecordingDisposition
  end
end

[hold_output, hold_version_output, disposition_output, migration_output] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "camera_recording_holds_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraRecordingHoldsSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_recording_holds_and_dispositions",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"camera_recording_holds", hold_output},
        {"camera_recording_holds_versions", hold_version_output},
        {"camera_recording_dispositions", disposition_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(
      Path.join(scratch, "migrations/*_add_camera_recording_holds_and_dispositions.exs")
    )

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
