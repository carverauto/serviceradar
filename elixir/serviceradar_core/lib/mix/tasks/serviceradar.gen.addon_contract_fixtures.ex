defmodule Mix.Tasks.Serviceradar.Gen.AddonContractFixtures do
  @shortdoc "Regenerate the add-on config contract fixtures under go/pkg/agent/testdata"

  @moduledoc """
  Regenerates `go/pkg/agent/testdata/addonconfig_contract/*.json` from the
  representative add-on assignment params in
  `ServiceRadar.Plugins.AddonConfigContractFixtures`, rendered through the
  real delivery path (schema coercion + validation + `config_json` encoding).

  Run after changing an add-on `config.schema.json`, the representative
  params, or the delivery-path coercion rules, then commit the updated
  fixtures (fj#4383):

      cd elixir/serviceradar_core
      mix serviceradar.gen.addon_contract_fixtures

  CI enforcement:

    * `test/serviceradar/edge/addon_config_contract_fixtures_test.exs` fails
      when the committed fixtures drift from what delivery emits.
    * The Go/Rust contract tests decode the committed fixtures with the real
      agent/add-on decoders and fail CI when a fixture stops decoding.
  """

  use Mix.Task

  alias ServiceRadar.Plugins.AddonConfigContractFixtures

  @impl true
  def run(_args) do
    # Pure rendering — needs compiled code, not the running app.
    Mix.Task.run("compile")

    for path <- AddonConfigContractFixtures.write_all!() do
      Mix.shell().info("wrote #{Path.relative_to_cwd(path)}")
    end
  end
end
