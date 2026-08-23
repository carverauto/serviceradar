# Derives SERVICERADAR_TEST_DATABASE_URL for the targets that talk to the per-run
# integration database, and must be loaded BEFORE //build:elixir_test_config_loader.exs --
# config/test.exs reads this variable while assembling ServiceRadar.Repo's settings, so
# setting it afterwards would have no effect.
#
# The base name is READ, not derived. //build:run_id_file writes it from --//build:run_id, and
# this suite, //rust/integration-db's provision and its teardown all read that ONE file at the
# same relative path, so there is no GITHUB_ENV handoff between steps, no ordering assumption
# about who wrote it first, and no second implementation of the format to keep in step.
#
# What this replaced: both sides independently formatted "sr_core_test_<run>_<attempt>" from
# GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT, and both fell back to the CONSTANT "sr_core_test_local"
# when those were absent. That fallback is why there is no fallback here -- two concurrent runs
# against one fixture landed on the same database and each teardown dropped the other's data.
# Failing closed is the point: a missing id must stop the suite, not silently repoint it.

# Where rules_elixir puts a declared input.
#
# `ex_unit_test` copies every `srcs` and `data` file to ${TEST_TMPDIR}/<workspace-relative path>
# and then cds to ${TEST_TMPDIR}/<package>, so the staged tree mirrors the workspace. That is the
# rule's contract, and naming it needs no repository name: an earlier version of this reached
# into TEST_SRCDIR and guessed "_main" then "serviceradar", which worked only because the
# runfiles tree happens to hold the file too.
#
# Deliberately no environment override -- a variable that can repoint an input lets a run read a
# file nothing in the build graph declared.
run_id_relative = "build/run_id_file.txt"

tmpdir =
  System.get_env("TEST_TMPDIR") ||
    raise "TEST_TMPDIR unset: #{run_id_relative} is staged by Bazel"

run_id_path = Path.join(tmpdir, run_id_relative)

if not File.exists?(run_id_path) do
  raise "cannot locate #{run_id_relative} at #{run_id_path}; " <>
          "add //build:run_id_file to this target's data"
end

base_name = run_id_path |> File.read!() |> String.trim()

# The guarded suite has exactly one legitimate endpoint. Resolve it from the typed
# SERVICERADAR_ENV instance, just as template migration and the Rust provisioner do. This
# deliberately overwrites any legacy SRQL_TEST_DATABASE_URL or direct Repo URL so provisioning
# and execution cannot be sent to different servers.
Code.require_file("fixture_config.exs", __DIR__)
Code.require_file("integration_env_config.exs", __DIR__)

ServiceRadar.DB.IntegrationEnvConfig.configure!(
  base_name,
  System.get_env("SERVICERADAR_TEST_DB_SHARD")
)
