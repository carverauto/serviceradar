# Generate the concrete manifest authority and incremental archive proof references.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraArchivePublicationSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.ArchiveManifestAuthority
    resource ServiceRadar.Camera.ArchiveUploadDispatch
    resource ServiceRadar.Camera.ArchiveUploadIntent
    resource ServiceRadar.Camera.RecordingBlock
  end
end

[authority_output, dispatch_output, intent_output, block_output, migration_output | baselines] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "camera_archive_publication_scratch")

for baseline <- baselines do
  directory = Path.join([scratch, "repo", Path.basename(Path.dirname(baseline))])
  File.mkdir_p!(directory)
  File.cp!(baseline, Path.join(directory, Path.basename(baseline)))
end

try do
  snapshots = AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.CameraArchivePublicationSchema, ServiceRadar.Repo)

  for table <- ~w(camera_archive_upload_dispatches camera_archive_upload_intents camera_recording_blocks) do
    current = Enum.find(snapshots, &(&1.table == table))
    previous = AshPostgres.MigrationGenerator.get_existing_snapshot(current,
      %AshPostgres.MigrationGenerator{snapshot_path: scratch})
    unless previous, do: raise("archive publication baseline was not found for #{table}")
  end

  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraArchivePublicationSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_archive_publication",
    # The pinned generator's no_shell mode ignores on-disk baselines.
    no_shell?: false,
    quiet: true,
    format: false
  )

  for {table, output} <- [{"camera_archive_manifest_authorities", authority_output},
                          {"camera_archive_upload_dispatches", dispatch_output},
                          {"camera_archive_upload_intents", intent_output},
                          {"camera_recording_blocks", block_output}] do
    snapshot = scratch |> Path.join("repo/platform.#{table}/*.json") |> Path.wildcard() |> Enum.sort() |> List.last()
    File.cp!(snapshot, output)
  end

  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_camera_archive_publication.exs"))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
