# Generate the Stage 1 Solution Packs & Catalog tables (`platform.catalog_repositories`,
# `platform.installed_solution_packs`, `platform.installed_solution_pack_credential_bindings`),
# check constraints, indexes, restrictive foreign keys, seeded official catalog row,
# and rule/dashboard pack provenance columns with the pinned AshPostgres toolchain.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.SolutionPacksSchema do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Catalog.CatalogRepository
    resource ServiceRadar.Catalog.InstalledSolutionPack
    resource ServiceRadar.Catalog.InstalledSolutionPackCredentialBinding
  end
end

[
  repository_output,
  installed_pack_output,
  binding_output,
  migration_output
] = System.argv()

scratch =
  Path.join(
    Path.dirname(migration_output),
    "solution_packs_schema_scratch"
  )

File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(
    ServiceRadar.SolutionPacksSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_solution_packs_and_catalog_repositories",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"catalog_repositories", repository_output},
        {"installed_solution_packs", installed_pack_output},
        {"installed_solution_pack_credential_bindings", binding_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(
      Path.join(
        scratch,
        "migrations/*_add_solution_packs_and_catalog_repositories.exs"
      )
    )

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
