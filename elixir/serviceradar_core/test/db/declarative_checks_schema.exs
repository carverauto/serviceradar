# Generate the Stage 1 DeclarativeChecks tables (`platform.declarative_checks`,
# `platform.declarative_check_credential_bindings`, `platform.declarative_check_instances`,
# `platform.declarative_check_edge_observations`), check constraints, indexes, and
# restrictive foreign keys with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.DeclarativeChecksSchema do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.DeclarativeChecks.DeclarativeCheck
    resource ServiceRadar.DeclarativeChecks.DeclarativeCheckCredentialBinding
    resource ServiceRadar.DeclarativeChecks.DeclarativeCheckInstance
    resource ServiceRadar.DeclarativeChecks.DeclarativeCheckEdgeObservation
  end
end

[
  check_output,
  binding_output,
  instance_output,
  edge_observation_output,
  migration_output
] = System.argv()

scratch =
  Path.join(
    Path.dirname(migration_output),
    "declarative_checks_schema_scratch"
  )

File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(
    ServiceRadar.DeclarativeChecksSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_declarative_checks",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"declarative_checks", check_output},
        {"declarative_check_credential_bindings", binding_output},
        {"declarative_check_instances", instance_output},
        {"declarative_check_edge_observations", edge_observation_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(
      Path.join(
        scratch,
        "migrations/*_add_declarative_checks.exs"
      )
    )

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
