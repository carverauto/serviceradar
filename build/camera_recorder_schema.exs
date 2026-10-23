# Isolated initial recorder schema generation, using the pinned Ash toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraRecorderSchema do
  use Ash.Domain, validate_config_inclusion?: false
  resources do
    resource ServiceRadar.Camera.RecorderClaim
  end
end

[snapshot_output, migration_output] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "camera_recorder_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraRecorderSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_recorder_claims",
    no_shell?: true,
    quiet: true,
    format: false
  )
  [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.camera_recorder_claims/*.json"))
  File.cp!(snapshot, snapshot_output)
  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_camera_recorder_claims.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
