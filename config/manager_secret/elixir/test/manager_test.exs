defmodule ServiceradarSecretTest do
  use ExUnit.Case, async: true

  alias ServiceradarSecret
  alias ServiceradarSecret.{Manifest, Secret, SecretError}

  # An in-memory provider, so the resolution paths are testable without a mount.
  defp map_provider(stored) do
    fn name ->
      case Secret.new(Map.get(stored, name, "")) do
        {:ok, secret} -> {:ok, secret}
        :error -> {:error, {:unresolvable, name, "test-map"}}
      end
    end
  end

  defp manager(declared, stored) do
    ServiceradarSecret.new("test-map", map_provider(stored), Manifest.new(declared))
  end

  test "a declared and stored secret resolves" do
    m = manager(["database.password"], %{"database.password" => "hunter2"})
    assert {:ok, secret} = ServiceradarSecret.resolve(m, "database.password")
    assert Secret.expose(secret) == "hunter2"
  end

  # Configuration gets least privilege from the build graph; a secret cannot be a build target, so
  # the symmetric mechanism is the declaration, enforced here.
  test "an undeclared name is refused even when the store has it" do
    m = manager(["database.password"], %{"database.password" => "hunter2", "nats.creds" => "x"})

    assert {:error, {:undeclared, "nats.creds", ["database.password"]} = err} =
             ServiceradarSecret.resolve(m, "nats.creds")

    assert SecretError.message(err) =~ "manifest"
  end

  # Refusal precedes resolution. Answering an undeclared name -- even to say "not found" -- tells a
  # component whether a secret it may not have exists.
  test "an undeclared name is refused identically whether or not it exists" do
    absent = manager(["database.password"], %{"database.password" => "h"})
    present = manager(["database.password"], %{"database.password" => "h", "nats.creds" => "x"})

    assert ServiceradarSecret.resolve(absent, "nats.creds") ==
             ServiceradarSecret.resolve(present, "nats.creds")
  end

  # There is no default and no empty fallback: a component that continued here would authenticate
  # with a blank credential.
  test "a declared but missing secret names the key and the provider" do
    m = manager(["database.password"], %{})

    assert {:error, {:unresolvable, "database.password", "test-map"} = err} =
             ServiceradarSecret.resolve(m, "database.password")

    message = SecretError.message(err)
    assert message =~ "no default"
    assert message =~ "blank credential"
  end

  test "an empty stored value does not resolve" do
    m = manager(["database.password"], %{"database.password" => ""})
    assert {:error, {:unresolvable, _, _}} = ServiceradarSecret.resolve(m, "database.password")
  end

  # Startup resolves everything declared. A component that resolves lazily discovers a missing
  # secret when it first needs it -- under load, and far from the deploy that caused it.
  test "resolve_all returns every declared secret" do
    m =
      manager(["database.password", "nats.creds"], %{
        "database.password" => "hunter2",
        "nats.creds" => "creds"
      })

    assert {:ok, resolved} = ServiceradarSecret.resolve_all(m)
    assert Enum.map(resolved, &elem(&1, 0)) == ["database.password", "nats.creds"]
  end

  test "resolve_all fails when any declared secret is missing" do
    m = manager(["database.password", "nats.creds"], %{"database.password" => "hunter2"})
    assert {:error, {:unresolvable, "nats.creds", _}} = ServiceradarSecret.resolve_all(m)
  end

  # explain has to report which store was consulted.
  test "the provider is reportable" do
    assert ServiceradarSecret.provider(manager([], %{})) == "test-map"
  end

  test "declared names are sorted, and an empty manifest declares nothing" do
    assert Manifest.declared(Manifest.new(["nats.creds", "core.key", "database.password"])) ==
             ["core.key", "database.password", "nats.creds"]

    empty = Manifest.new()
    assert Manifest.empty?(empty)
    refute Manifest.declares?(empty, "database.password")
  end

  # A secret error names a KEY, never a value -- these are the strings that reach logs.
  test "no secret error can carry a value" do
    for err <- [
          {:undeclared, "k", ["d"]},
          {:unresolvable, "k", "p"},
          {:provider_failed, "k", "p", "d"}
        ] do
      refute SecretError.message(err) =~ "hunter2"
    end
  end
end
