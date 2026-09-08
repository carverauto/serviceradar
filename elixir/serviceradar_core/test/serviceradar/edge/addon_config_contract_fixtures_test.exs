defmodule ServiceRadar.Edge.AddonConfigContractFixturesTest do
  @moduledoc """
  Drift gate for the add-on config contract fixtures (fj#4383).

  The committed fixtures under `go/pkg/agent/testdata/addonconfig_contract/`
  are what the Go/Rust contract tests decode with the real agent/add-on
  decoders. This test fails when the delivery path (schema coercion +
  validation + `config_json` encoding) stops emitting exactly the committed
  bytes — regenerate with:

      cd elixir/serviceradar_core
      mix serviceradar.gen.addon_contract_fixtures

  and commit the updated fixtures.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.AddonConfigContractFixtures, as: Fixtures
  alias ServiceRadar.Plugins.ConfigSchema

  @moduletag :requires_app

  test "covers every bundled add-on named by the spec" do
    assert Fixtures.addon_ids() == [
             "anomaly-addon",
             "bumblebee-scan",
             "netprobe",
             "otel-collector",
             "rdp-adapter",
             "scalibr-endpoint-inventory",
             "workload-identity"
           ]
  end

  for addon_id <- Fixtures.addon_ids() do
    @addon_id addon_id

    test "committed fixture for #{addon_id} matches what delivery emits" do
      path = Fixtures.fixture_path(@addon_id)

      assert File.exists?(path),
             "missing contract fixture #{path} — run " <>
               "`mix serviceradar.gen.addon_contract_fixtures` and commit the result"

      assert File.read!(path) == Fixtures.rendered_config_json(@addon_id),
             "contract fixture #{path} is stale — run " <>
               "`mix serviceradar.gen.addon_contract_fixtures` and commit the result"
    end
  end

  test "non-empty fixtures validate against their add-on's config schema" do
    for addon_id <- Fixtures.addon_ids(),
        fixture = File.read!(Fixtures.fixture_path(addon_id)),
        fixture != "" do
      decoded = Jason.decode!(fixture)

      assert ConfigSchema.validate_params(Fixtures.schema(addon_id), decoded) == :ok,
             "fixture for #{addon_id} does not conform to addons/#{addon_id}/config.schema.json"
    end
  end

  test "rdp-adapter delivers no config bytes (its schema declares zero properties)" do
    # The rdp-adapter binary has no config decoder (stdio wire protocol);
    # delivery emits empty config_json, which the agent skips entirely.
    assert File.read!(Fixtures.fixture_path("rdp-adapter")) == ""
  end
end
