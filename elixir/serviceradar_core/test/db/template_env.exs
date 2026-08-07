# Points ServiceRadar.Repo at the shared template database, for //elixir/serviceradar_core:migrate_template.
#
# Must be loaded BEFORE //build:elixir_test_config_loader.exs -- config/test.exs reads
# SERVICERADAR_TEST_DATABASE_URL while assembling the Repo settings, so setting it afterwards
# would have no effect.
#
# The counterpart of test/db/integration_env.exs, which points the SUITE at the per-run
# database. This one points the MIGRATOR at the template that per-run database is cloned
# from, so the 368 migrations are applied once and every later run gets them as a file copy.
#
# Keep the name in step with `TEMPLATE_DATABASE` in rust/integration-db/src/template.rs. The
# two must agree exactly or the migrator advances a database nothing clones.
template_database = "sr_core_template"

base = System.get_env("SRQL_TEST_DATABASE_URL")

if is_binary(base) and base != "" do
  uri = URI.parse(base)

  if uri.scheme not in ["postgres", "postgresql", "ecto"] do
    raise "SRQL_TEST_DATABASE_URL has unexpected scheme #{inspect(uri.scheme)}"
  end

  # Replace only the path; the authority and any query (sslmode=...) survive untouched.
  derived = URI.to_string(%{uri | path: "/" <> template_database})

  # Unconditional, unlike integration_env.exs: this target has exactly one legitimate
  # destination. Honouring a pre-set SERVICERADAR_TEST_DATABASE_URL here would silently
  # migrate a per-run database instead, leaving the template behind and every later run
  # cloning a stale schema.
  System.put_env("SERVICERADAR_TEST_DATABASE_URL", derived)
else
  raise """
  SRQL_TEST_DATABASE_URL is required to derive the template database URL.

  Without it config/test.exs would fall back to a local development database and the
  migrations would be applied there, leaving the template untouched and the failure
  invisible until the suite ran against a stale clone.
  """
end
