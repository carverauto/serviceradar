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
disposable_prefix = "sr_core_test_"

# Bazel runs this out of a runfiles tree where a bare relative path resolves to nothing. Same
# idiom as ServiceradarConfig.TestPaths.data!/1 and the Rust `runfile` helper; deliberately no
# environment override, because a variable that can repoint an input lets a run read a file
# nothing in the build graph declared.
run_id_relative = "build/run_id_file.txt"

srcdir =
  System.get_env("TEST_SRCDIR") ||
    raise "TEST_SRCDIR unset: #{run_id_relative} is staged by Bazel"

run_id_path =
  ["_main", "serviceradar"]
  |> Enum.map(&Path.join([srcdir, &1, run_id_relative]))
  |> Enum.find(&File.exists?/1)
  |> case do
    nil ->
      raise "cannot locate #{run_id_relative} under #{srcdir}; " <>
              "add //build:run_id_file to this target's data"

    path ->
      path
  end

base_name = run_id_path |> File.read!() |> String.trim()

# Fail closed, with the same guidance //rust/integration-db gives. An empty file is what
# //build:run_id_file writes when the flag is unset.
if base_name == "" do
  raise """
  --//build:run_id is not set, so there is no database name to operate on.

  Every step of the integration lifecycle derives its disposable database from this one
  value, and it has no default ON PURPOSE: a constant fallback name lets two runs against
  the same fixture share a database, and each teardown then drops the other's data.

  Mint one id and pass it to EVERY invocation of the sequence:

      RUN_ID=$(uuidgen | tr -d - | tr 'A-Z' 'a-z' | cut -c1-8)
  """
end

# The prefix is written by //build/run_id.bzl and checked here independently, exactly as
# rust/integration-db/src/lib.rs does. If the two ever drift this must fail rather than point a
# suite -- and the teardown that follows it -- outside the disposable namespace.
if not String.starts_with?(base_name, disposable_prefix) do
  raise "run id file holds #{inspect(base_name)}, which does not start with " <>
          "#{inspect(disposable_prefix)}"
end

# Same shape Rust enforces (MIN_RUN_ID_BYTES/MAX_RUN_ID_BYTES in rust/integration-db). An
# unquoted dash or an uppercase letter in a PostgreSQL identifier is a different database or a
# syntax error depending on where it lands, so raw `uuidgen` output must not pass either side.
run_id = String.replace_prefix(base_name, disposable_prefix, "")

if not String.match?(run_id, ~r/\A[a-z0-9]{8,32}\z/) do
  raise "--//build:run_id must be 8..32 characters of [a-z0-9], got #{inspect(run_id)} -- " <>
          "mint one with `uuidgen | tr -d - | tr 'A-Z' 'a-z' | cut -c1-8`"
end

# Each shard gets its OWN database. The suite is split across parallel Bazel targets, and
# Ecto's SQL sandbox isolates concurrent tests within a BEAM VM but not across OS processes
# -- parallel shards against one database deadlock (40P01). The suffix is set per target by
# //build:integration_shards.bzl; //rust/integration-db clones the same set of names.
#
# Absent (an unsharded or hand-run target) the base name is used unchanged.
database =
  case System.get_env("SERVICERADAR_TEST_DB_SHARD") do
    shard when is_binary(shard) and shard != "" ->
      if !String.match?(shard, ~r/\A[a-z0-9_]+\z/) do
        raise "SERVICERADAR_TEST_DB_SHARD must be [a-z0-9_]+, got #{inspect(shard)}"
      end

      "#{base_name}_#{shard}"

    _ ->
      base_name
  end

# Only derive when the fixture URL is present and nothing has already pinned an explicit
# target, so a developer pointing at their own database is never overridden.
base = System.get_env("SRQL_TEST_DATABASE_URL")

if is_binary(base) and base != "" and
     System.get_env("SERVICERADAR_TEST_DATABASE_URL") in [nil, ""] do
  uri = URI.parse(base)

  if uri.scheme not in ["postgres", "postgresql", "ecto"] do
    raise "SRQL_TEST_DATABASE_URL has unexpected scheme #{inspect(uri.scheme)}"
  end

  # Replace only the path; the authority and any query (sslmode=...) survive untouched.
  derived = URI.to_string(%{uri | path: "/" <> database})

  System.put_env("SERVICERADAR_TEST_DATABASE_URL", derived)
end
