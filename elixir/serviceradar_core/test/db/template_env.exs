# Points ServiceRadar.Repo at the shared template database, for //elixir/serviceradar_core:migrate_template.
#
# Must be loaded BEFORE //build:elixir_test_config_loader.exs -- config/test.exs reads
# SERVICERADAR_TEST_DATABASE_URL while assembling the Repo settings, so setting it afterwards
# would have no effect. test/db/fixture_config.exs is loaded before this one for the same reason.
#
# The counterpart of test/db/integration_env.exs, which points the SUITE at the per-run
# database. This one points the MIGRATOR at the template that per-run database is cloned
# from, so the 368 migrations are applied once and every later run gets them as a file copy.
#
# Keep the name in step with `TEMPLATE_DATABASE` in rust/integration-db/src/template.rs. The
# two must agree exactly or the migrator advances a database nothing clones.
template_database = "sr_core_template"

# WHAT THIS REPLACED, and why it is not simply a smaller edit.
#
# It read SRQL_TEST_DATABASE_URL -- a whole DSN carrying host, port, database, user, password and
# sslmode -- and rewrote the path to point at the template. That made a CI secret the source of
# an ENDPOINT: the fixture's address lived in BuildBuddy rather than in this repository, so it
# could not be reviewed, could not differ per environment without a second secret, and had to be
# parsed back apart to change one component of it.
#
# Now `SERVICERADAR_ENV` names an environment, //config/environments/<kind>.textproto declares
# its coordinates as typed fields, and SecretManager resolves the one thing that is actually
# secret. The database name is SUBSTITUTED into an assembled DSN rather than rewritten into a
# parsed one.
fixture = ServiceRadar.DB.FixtureConfig.resolve!(template_database)

# Config/test.exs allows the long-lived clone template only when this typed preloader has marked
# the current BEAM. An ambient flag cannot opt an ordinary Mix invocation into the exception.
guard_path = Path.expand("../../config/test_database_guard.exs", __DIR__)
Code.require_file(guard_path)
ServiceRadar.DB.TestDatabaseGuard.authorize_template_lifecycle!()

# System.put_env, still, and deliberately: this is a handoff INSIDE one OS process to
# config/test.exs, which is a Config script evaluated before any of our code can pass it a value
# by any other means. What changed is where the values come from -- configuration and
# SecretManager, rather than variables a CI system injected.
#
# Unconditional, because this target has exactly one legitimate destination. Honouring a pre-set
# SERVICERADAR_TEST_DATABASE_URL here would silently migrate a per-run database instead, leaving
# the template behind and every later run cloning a stale schema.
System.put_env("SERVICERADAR_TEST_DATABASE_URL", fixture.url)

# Both are read by config/test.exs. The CA is PEM CONTENT rather than a path, so it does not
# depend on a filesystem layout the action does not control; the server name is what verify-full
# checks the certificate against, which matters whenever the connection is made by address.
if fixture.ca_pem do
  System.put_env("SERVICERADAR_TEST_DATABASE_CA_CERT", fixture.ca_pem)
end

if fixture.tls_server_name do
  System.put_env("SERVICERADAR_TEST_DATABASE_SERVER_NAME", fixture.tls_server_name)
end
