defmodule ServiceradarSecret.EnvProviderTest do
  @moduledoc """
  `EnvProvider` reads secrets from the process environment.

  Mirrors //config/manager_secret/rust/tests/traits/env_provider_tests.rs. The variable-name
  cases are the ones that must not drift: a Rust component and an Elixir component resolving the
  same logical name have to read the same variable, or one of them silently sees nothing.
  """
  use ExUnit.Case, async: false

  alias ServiceradarSecret.{EnvProvider, Secret}

  # The whole point of the transform: a caller that knows the logical name can compute the
  # variable, so no mapping table exists to disagree with the manifest.
  test "the variable is derived from the logical name" do
    assert EnvProvider.variable_for("database.password") ==
             "SERVICERADAR_SECRET_DATABASE_PASSWORD"

    assert EnvProvider.variable_for("database.admin_password") ==
             "SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD"
  end

  test "every separator becomes an underscore" do
    assert EnvProvider.variable_for("a.b-c/d") == EnvProvider.prefix() <> "A_B_C_D"
  end

  test "an unset variable is unresolvable and names the provider" do
    name = "database.password"
    delete_secret(name)

    assert {:error, {:unresolvable, ^name, label}} = EnvProvider.resolve(EnvProvider.new(), name)
    assert String.starts_with?(label, "env("), "the error must name the store consulted: #{label}"
  end

  # A set-but-blank secret is the failure this guards: it authenticates as nobody and the server
  # reports something unrelated. Absent and empty must be the same answer here.
  test "an empty variable is absent, not an empty credential" do
    name = "database.password"
    put_secret(name, "")

    assert {:error, {:unresolvable, ^name, _label}} =
             EnvProvider.resolve(EnvProvider.new(), name)
  end

  test "a set variable resolves without its trailing newline" do
    name = "database.ca_cert"
    put_secret(name, "value\n")

    assert {:ok, secret} = EnvProvider.resolve(EnvProvider.new(), name)
    assert Secret.expose(secret) == "value"
  end

  defp put_secret(name, value) do
    variable = EnvProvider.variable_for(name)
    System.put_env(variable, value)
    on_exit(fn -> System.delete_env(variable) end)
  end

  defp delete_secret(name) do
    variable = EnvProvider.variable_for(name)
    System.delete_env(variable)
  end
end
