Code.require_file("support_paths.exs", __DIR__)

defmodule ServiceradarConfig.ValidatorVectorTest do
  @moduledoc """
  The Elixir engine reproduces the committed conformance vectors.

  This is the third implementation, and the reason the vector file is data rather than three
  hand-maintained test suites: a disagreement between Elixir and Rust shows up here as a named
  failing fixture, instead of as a service that starts in one language and refuses in another.
  """

  use ExUnit.Case, async: true

  alias Serviceradar.Config.V1.{EnvironmentConfig, FixtureSet, RuleSet}
  alias ServiceradarConfig.TestPaths
  alias ServiceradarConfig.Validator

  setup_all do
    %{
      rules: TestPaths.decode!("config/rules/ruleset.binpb", RuleSet),
      fixtures: TestPaths.decode!("config/rules/fixtures/fixtures.binpb", FixtureSet)
    }
  end

  test "every fixture produces exactly its expected violations", %{rules: rules, fixtures: set} do
    refute Enum.empty?(set.fixtures), "the fixture set decoded empty"

    failures =
      for fixture <- set.fixtures,
          {:ok, actual} = Validator.validate(rules, fixture.instance),
          expected = Enum.map(fixture.expected_violations, &{&1.code, &1.field_path}),
          got = Enum.map(actual, &{&1.code, &1.field_path}),
          got != expected do
        "#{fixture.name}:\n    expected #{inspect(expected)}\n    actual   #{inspect(got)}"
      end

    assert failures == [], "fixture mismatches:\n  " <> Enum.join(failures, "\n  ")
  end

  test "every committed instance is clean", %{rules: rules} do
    for name <- ~w(ci demo localhost onprem/untd saas) do
      cfg = TestPaths.decode!("config/environments/#{name}.binpb", EnvironmentConfig)
      assert {:ok, []} = Validator.validate(rules, cfg), "#{name} has violations"
    end
  end
end
