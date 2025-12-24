# Start required applications for tests without starting the full app
# This allows unit tests to run without requiring a database
Application.ensure_all_started(:telemetry)

ExUnit.start(exclude: [:integration])

# For integration tests that need the database, use:
# mix test --include integration
#
# And ensure the database is set up first:
# mix ecto.create && mix ecto.migrate
