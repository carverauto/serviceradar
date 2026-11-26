# Generate the Vantage ML Pipelines, Jobs, Observations, and Worker Registrations
# snapshots and base migration against an isolated Ash domain so unrelated
# resource drift never leaks into the migration.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.VantageMLPipelinesSchema do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Camera.VantagePipeline
    resource ServiceRadar.Camera.VantageJob
    resource ServiceRadar.Camera.VantageObservation
    resource ServiceRadar.Camera.VantageWorkerRegistration
  end
end

[
  pipeline_output,
  job_output,
  observation_output,
  worker_reg_output,
  migration_output
] = System.argv()

scratch =
  Path.join(
    Path.dirname(migration_output),
    "vantage_ml_pipelines_schema_scratch"
  )

File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(
    ServiceRadar.VantageMLPipelinesSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_vantage_ml_pipelines_and_observations",
    no_shell?: true,
    quiet: true,
    format: false
  )

  for {table, output} <- [
        {"camera_vantage_pipelines", pipeline_output},
        {"camera_vantage_jobs", job_output},
        {"camera_vantage_observations", observation_output},
        {"vantage_worker_registrations", worker_reg_output}
      ] do
    [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
    File.cp!(snapshot, output)
  end

  [migration] =
    Path.wildcard(
      Path.join(
        scratch,
        "migrations/*_add_vantage_ml_pipelines_and_observations.exs"
      )
    )

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
