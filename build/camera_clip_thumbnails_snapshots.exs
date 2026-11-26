Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraClipThumbnailsSnapshots do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.RecordingCatalogEntry
  end
end

[catalog_output] = System.argv()

scratch = Path.join(Path.dirname(catalog_output), "camera_clip_thumbnails_snapshots_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraClipThumbnailsSnapshots,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    snapshots_only: true,
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [{"camera_recording_catalog", catalog_output}] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.mkdir_p!(Path.dirname(output))
    File.cp!(snapshot, output)
  end
after
  File.rm_rf!(scratch)
end
