# Generate the receipt table with the repository's pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraQualificationReceiptSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.ArchiveQualificationReceipt
  end
end

[snapshot_output, migration_output] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "camera_qualification_receipt_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraQualificationReceiptSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_archive_qualification_receipts",
    no_shell?: true,
    quiet: true,
    format: false
  )

  [snapshot] =
    Path.wildcard(Path.join(scratch, "repo/platform.camera_archive_qualification_receipts/*.json"))

  File.cp!(snapshot, snapshot_output)

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_camera_archive_qualification_receipts.exs"))

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
