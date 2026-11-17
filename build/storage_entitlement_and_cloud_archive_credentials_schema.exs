# Generate the Stage F StorageEntitlement (with PaperTrail storage_entitlement_versions),
# StorageUsageDailyReport, and network_credential_secrets Cloud-managed columns,
# check constraints, and indexes with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.StorageEntitlementAndCloudArchiveCredentialsSchema do
  @moduledoc false
  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Storage.StorageEntitlement
    resource ServiceRadar.Storage.StorageUsageDailyReport
  end
end

[
  entitlement_output,
  entitlement_version_output,
  usage_report_output,
  migration_output
] = System.argv()

scratch =
  Path.join(
    Path.dirname(migration_output),
    "storage_entitlement_and_cloud_archive_credentials_schema_scratch"
  )

File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(
    ServiceRadar.StorageEntitlementAndCloudArchiveCredentialsSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_storage_entitlement_and_cloud_archive_credentials",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"storage_entitlements", entitlement_output},
        {"storage_entitlement_versions", entitlement_version_output},
        {"storage_usage_daily_reports", usage_report_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(
      Path.join(
        scratch,
        "migrations/*_add_storage_entitlement_and_cloud_archive_credentials.exs"
      )
    )

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
