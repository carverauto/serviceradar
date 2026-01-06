# Start required applications for tests without starting the full app
# This allows unit tests to run without requiring a database
Application.ensure_all_started(:telemetry)

if System.get_env("SRQL_TEST_DATABASE_URL") ||
     System.get_env("SERVICERADAR_TEST_DATABASE_URL") ||
     System.get_env("SRQL_TEST_DATABASE_URL_FILE") ||
     System.get_env("SERVICERADAR_TEST_DATABASE_URL_FILE") do
  ExUnit.start()
  ServiceRadar.TestSupport.start_core!()
else
  ExUnit.start(exclude: [:integration])
end

# For integration tests that need the database, use:
# mix test --include integration
#
# And ensure the database is set up first:
# mix ecto.create && mix ecto.migrate
