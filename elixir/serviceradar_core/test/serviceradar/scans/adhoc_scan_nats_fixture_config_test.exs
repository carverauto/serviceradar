defmodule ServiceRadar.Scans.AdhocScanNatsFixtureConfigTest do
  @moduledoc """
  Guards the sr-testing NATS fixture CONFIGURATION itself.

  Deliberately does NOT use `DataCase`: a partial configuration must report which
  variables are missing even where no database is reachable. Keeping it separate
  from the database-backed E2E source also lets the integration lane inventory
  classify this module as async without loading the fixed-resource NATS test.
  """

  use ExUnit.Case, async: true

  @nats_vars ["NATS_TEST_HOST", "NATS_TEST_CERT_DIR"]
  @nats_present Enum.filter(@nats_vars, &(System.get_env(&1) not in [nil, ""]))
  @nats_missing @nats_vars -- @nats_present
  @nats_partial @nats_present != [] and @nats_missing != []

  @moduletag :integration
  @moduletag :external
  @moduletag skip: not @nats_partial

  test "the sr-testing NATS fixture is fully configured or not configured at all" do
    flunk(
      "sr-testing NATS fixture is PARTIALLY configured; missing: " <>
        Enum.join(@nats_missing, ", ") <>
        ". Set all of " <>
        Enum.join(@nats_vars, ", ") <>
        " (plus NATS_TEST_CA_CERT / NATS_TEST_CLIENT_CERT / NATS_TEST_CLIENT_KEY in CI), " <>
        "or none of them. A partial configuration must fail rather than silently " <>
        "skip the integration coverage."
    )
  end
end
