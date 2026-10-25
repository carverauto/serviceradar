# Generate only init authority and the incremental dispatch grant columns.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraInitAuthoritySchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.ArchiveInitAuthority
    resource ServiceRadar.Camera.ArchiveUploadDispatch
  end
end

[authority_output, dispatch_output, migration_output, baseline] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "camera_init_authority_scratch")
dispatch_snapshots = Path.join(scratch, "repo/platform.camera_archive_upload_dispatches")
File.mkdir_p!(dispatch_snapshots)
File.cp!(baseline, Path.join(dispatch_snapshots, Path.basename(baseline)))

try do
  current = ServiceRadar.CameraInitAuthoritySchema
    |> AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.Repo)
    |> Enum.find(&(&1.table == "camera_archive_upload_dispatches"))
  previous = AshPostgres.MigrationGenerator.get_existing_snapshot(current,
    %AshPostgres.MigrationGenerator{snapshot_path: scratch})
  unless previous, do: raise("camera dispatch baseline was not found")

  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraInitAuthoritySchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_init_authority",
    # The pinned generator's no_shell mode ignores on-disk baselines.
    no_shell?: false,
    quiet: true,
    format: false
  )

  for {table, output} <- [{"camera_archive_init_authorities", authority_output},
                          {"camera_archive_upload_dispatches", dispatch_output}] do
    snapshot = scratch |> Path.join("repo/platform.#{table}/*.json") |> Path.wildcard() |> Enum.sort() |> List.last()
    File.cp!(snapshot, output)
  end

  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_camera_init_authority.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
