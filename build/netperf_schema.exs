# Executed only by the declared Bazel schema-generation action with pinned
# AshPostgres, OTP and Elixir. This domain scopes codegen to the netperf resources.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.NetperfSchema do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ServiceRadar.Monitoring.NetperfProfile
    resource ServiceRadar.Monitoring.NetperfResponder
    resource ServiceRadar.Monitoring.NetperfPolicy
    resource ServiceRadar.Monitoring.NetperfPolicyResponder
  end
end

[
  profile_output,
  responder_output,
  policy_output,
  policy_responder_output,
  migration_output
] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "netperf_schema_scratch")
File.mkdir_p!(scratch)

try do
  AshPostgres.MigrationGenerator.generate(ServiceRadar.NetperfSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_netperf_monitoring_resources",
    no_shell?: true,
    quiet: true,
    format: false
  )

  Enum.each(
    [
      {"netperf_profiles", profile_output},
      {"netperf_responders", responder_output},
      {"netperf_policies", policy_output},
      {"netperf_policy_responders", policy_responder_output}
    ],
    fn {table, output} ->
      [snapshot] = Path.wildcard(Path.join(scratch, "repo/platform.#{table}/*.json"))
      File.mkdir_p!(Path.dirname(output))
      File.cp!(snapshot, output)
    end
  )

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_netperf_monitoring_resources.exs"))

  File.mkdir_p!(Path.dirname(migration_output))
  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
