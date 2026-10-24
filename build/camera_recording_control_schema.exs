# Generate only the stop-control table with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraRecordingControlSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.RecordingControlState
  end
end

[snapshot_output, migration_output] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "camera_recording_control_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraRecordingControlSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_recording_control",
    no_shell?: true,
    quiet: true,
    format: false
  )

  [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.camera_recording_control/*.json"))
  File.cp!(snapshot, snapshot_output)
  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_camera_recording_control.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
