# Generate the Stage A/C camera recording policies and per-member NVR storage settings
# tables (with AshPaperTrail version tables), indexes, restrictive FKs, and check
# constraints with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraRecordingPolicyAndStorageSettingsSchema do
  @moduledoc false
  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Camera.CameraRecordingPolicy
    resource ServiceRadar.Camera.NVRStorageSettings
  end
end

[
  policy_output,
  policy_version_output,
  storage_settings_output,
  storage_settings_version_output,
  migration_output
] = System.argv()

scratch =
  Path.join(
    Path.dirname(migration_output),
    "camera_recording_policy_and_storage_settings_schema_scratch"
  )

File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(
    ServiceRadar.CameraRecordingPolicyAndStorageSettingsSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_recording_policies_and_storage_settings",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"camera_recording_policies", policy_output},
        {"camera_recording_policies_versions", policy_version_output},
        {"camera_nvr_storage_settings", storage_settings_output},
        {"camera_nvr_storage_settings_versions", storage_settings_version_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(
      Path.join(
        scratch,
        "migrations/*_add_camera_recording_policies_and_storage_settings.exs"
      )
    )

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
