# Generate managed certificate authority snapshots with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.ComponentCertificateSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Edge.ManagedCertificatePolicyKey
    resource ServiceRadar.Edge.ManagedCertificateNatsConfig
    resource ServiceRadar.Edge.ManagedComponent
    resource ServiceRadar.Edge.ComponentCertificate
    resource ServiceRadar.Edge.RevokedComponentCertificate
  end
end

[component_output, certificate_output, revocation_output, nats_output, policy_output,
 migration_output] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "component_certificate_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.ComponentCertificateSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_component_certificate_authority",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"managed_components", component_output},
        {"component_certificates", certificate_output},
        {"revoked_component_certificates", revocation_output},
        {"managed_certificate_nats_config", nats_output},
        {"managed_certificate_policy_key", policy_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_component_certificate_authority.exs"))

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
