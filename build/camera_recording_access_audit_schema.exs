# Generate the Stage D append-only RecordingAccessAudit table, indexes, FK,
# check constraints, and BEFORE UPDATE OR DELETE trigger with the pinned
# AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraRecordingAccessAuditSchema do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.RecordingAccessAudit
  end
end

[audit_output, migration_output] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "camera_recording_access_audit_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraRecordingAccessAuditSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_recording_access_audit",
    no_shell?: true,
    quiet: true,
    format: false
  )

  [snapshot] =
    Path.wildcard(Path.join(scratch, "repo/platform.camera_recording_access_audits/*.json"))

  File.cp!(snapshot, audit_output)

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_camera_recording_access_audit.exs"))

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
