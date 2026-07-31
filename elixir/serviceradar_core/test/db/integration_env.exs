# Derives SERVICERADAR_TEST_DATABASE_URL for the targets that talk to the per-run
# integration database, and must be loaded BEFORE //build:elixir_test_config_loader.exs --
# config/test.exs reads this variable while assembling ServiceRadar.Repo's settings, so
# setting it afterwards would have no effect.
#
# The name is DERIVED, not handed over. //rust/integration-db computes the same value from
# the same two variables in provision, sweep and teardown, so there is no GITHUB_ENV handoff
# between steps and no ordering assumption about who wrote it first. Keep this in step with
# `database_name/0` in rust/integration-db/src/lib.rs; the two must agree exactly or the
# suite runs against a database nothing provisioned.
#
# Absent GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT this falls back to the same local name the Rust
# side uses, which keeps a developer fixture usable.
disposable_prefix = "sr_core_test_"

numeric? = fn
  nil -> false
  "" -> false
  value -> String.match?(value, ~r/\A\d+\z/)
end

run_id = System.get_env("GITHUB_RUN_ID")
attempt = System.get_env("GITHUB_RUN_ATTEMPT")

base_name =
  if numeric?.(run_id) and numeric?.(attempt) do
    "#{disposable_prefix}#{run_id}_#{attempt}"
  else
    "#{disposable_prefix}local"
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
      unless String.match?(shard, ~r/\A[a-z0-9_]+\z/) do
        raise "SERVICERADAR_TEST_DB_SHARD must be [a-z0-9_]+, got #{inspect(shard)}"
      end

      "#{base_name}_#{shard}"

    _ ->
      base_name
  end

# Only derive when the fixture URL is present and nothing has already pinned an explicit
# target, so a developer pointing at their own database is never overridden.
base = System.get_env("SRQL_TEST_DATABASE_URL")

if is_binary(base) and base != "" and System.get_env("SERVICERADAR_TEST_DATABASE_URL") in [nil, ""] do
  uri = URI.parse(base)

  unless uri.scheme in ["postgres", "postgresql", "ecto"] do
    raise "SRQL_TEST_DATABASE_URL has unexpected scheme #{inspect(uri.scheme)}"
  end

  # Replace only the path; the authority and any query (sslmode=...) survive untouched.
  derived = URI.to_string(%{uri | path: "/" <> database})

  System.put_env("SERVICERADAR_TEST_DATABASE_URL", derived)
end
