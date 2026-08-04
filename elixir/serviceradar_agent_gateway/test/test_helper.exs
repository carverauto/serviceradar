# The serviceradar_core Application starts:
# - PubSub for cluster events
# - PollerRegistry and AgentRegistry for registration support
#
# Under `mix test` those start automatically, because mix starts the application before
# running the suite. The Bazel target //elixir/serviceradar_agent_gateway:unit_tests does
# not: it runs the files with `elixir -r`, so nothing is started and no database is
# available. Modules that need a running ServiceRadar therefore carry
# `@moduletag :requires_app` and are excluded unless a database URL is present, which
# mirrors elixir/serviceradar_core/test/test_helper.exs.
#
# NOTE: adding a tag here does NOT keep a module out of a run that explicitly includes it.
# ExUnit runs a test matching an `include` filter even when it also matches an `exclude`
# one, so `mix test --include requires_app` re-includes every tagged module.
# Blank counts as absent, matching //elixir/serviceradar_core/test/test_helper.exs. See the
# longer note there: System.get_env/1 returns "" for a set-but-empty variable and "" is truthy
# in Elixir, and //build/elixir_tests.bzl pins these four to "" on every unit group because
# Bazel can set a variable for an action but never unset one.
database_available? =
  Enum.any?(
    ~w(
      SRQL_TEST_DATABASE_URL
      SERVICERADAR_TEST_DATABASE_URL
      SRQL_TEST_DATABASE_URL_FILE
      SERVICERADAR_TEST_DATABASE_URL_FILE
    ),
    fn name -> String.trim(System.get_env(name) || "") != "" end
  )

if database_available? do
  ExUnit.start()
else
  ExUnit.start(exclude: [:requires_app])
end
