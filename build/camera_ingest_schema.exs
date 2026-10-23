# The declared Bazel action runs Ash codegen with the repository's pinned
# dependencies. Restrict the domain so unrelated schema drift cannot be emitted.
# This is the initial schema generator. The committed snapshots are the baseline
# for later incremental migrations; those must not rewrite this migration.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraIngestSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.IngestOwner
    resource ServiceRadar.Camera.ConsumerLease
  end
end

[owner_output, consumer_output, migration_output] = System.argv()
scratch = Path.join(Path.dirname(migration_output), "camera_ingest_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraIngestSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_ingest_ownership",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [{"camera_ingest_owners", owner_output}, {"camera_consumer_leases", consumer_output}] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.mkdir_p!(Path.dirname(output))
    File.cp!(snapshot, output)
  end

  [migration] = Path.wildcard(Path.join(scratch, "migrations/*_add_camera_ingest_ownership.exs"))
  source = File.read!(migration)
  File.write!(migration_output, [Code.format_string!(source), "\n"])
after
  File.rm_rf!(scratch)
end
