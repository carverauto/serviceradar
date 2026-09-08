defmodule ServiceradarSecret.EnvironmentProviderTest do
  @moduledoc """
  Which provider each environment selects.

  Mirrors //config/manager_secret/rust/tests/traits/environment_provider_tests.rs.
  """
  use ExUnit.Case, async: false

  alias ServiceradarSecret.{EnvironmentProvider, Manifest, Secret}

  # Every deployed environment reads the environment, because that is what the platform does:
  # //helm/serviceradar supplies credentials with `valueFrom.secretKeyRef`, and a BuildBuddy
  # workflow secret has no other form.
  test "deployed environments read the environment" do
    for kind <- ["ci", "saas", "demo", "onprem"] do
      described = kind |> EnvironmentProvider.for_kind() |> EnvironmentProvider.describe()
      assert String.starts_with?(described, "env("), "#{kind} selected #{described}"
    end
  end

  # A developer machine has nothing injecting variables into a test action.
  test "localhost reads the file store" do
    described = "localhost" |> EnvironmentProvider.for_kind() |> EnvironmentProvider.describe()
    assert String.starts_with?(described, "file("), "localhost selected #{described}"
  end

  test "the manager resolves a declared secret through the selected provider" do
    name = "database.password"
    variable = ServiceradarSecret.EnvProvider.variable_for(name)
    System.put_env(variable, "resolved")
    on_exit(fn -> System.delete_env(variable) end)

    manager = EnvironmentProvider.manager("ci", Manifest.new([name]))

    assert {:ok, secret} = ServiceradarSecret.resolve(manager, name)
    assert Secret.expose(secret) == "resolved"
  end

  # The manifest is checked before the provider is consulted, so selecting a provider must not
  # widen what a component can read.
  test "an undeclared name is refused even when the variable is set" do
    declared = "database.password"
    undeclared = "database.admin_password"
    variable = ServiceradarSecret.EnvProvider.variable_for(undeclared)
    System.put_env(variable, "resolved")
    on_exit(fn -> System.delete_env(variable) end)

    manager = EnvironmentProvider.manager("ci", Manifest.new([declared]))

    assert {:error, {:undeclared, ^undeclared, [^declared]}} =
             ServiceradarSecret.resolve(manager, undeclared)
  end
end
