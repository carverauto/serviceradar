Code.require_file("support_fixtures.exs", __DIR__)

defmodule ServiceradarConfig.ManagerTest do
  use ExUnit.Case, async: true

  alias ServiceradarConfig.Manager
  alias ServiceradarConfig.Manager.{Identity, LoadError, Source}
  alias ServiceradarConfig.ManagerFixtures, as: F

  defp identity(value) do
    {:ok, id} = Identity.parse(value)
    id
  end

  # localhost and ci carry their instance because neither has a platform to mount anything: a
  # developer running a release directly and a Bazel test action both have a filesystem nobody
  # provisioned.
  test "kinds without a platform carry their instance" do
    for value <- ~w(localhost ci) do
      assert %Source{kind: :built_in, name: ^value} = Source.for_identity(identity(value))
    end
  end

  test "deployed kinds read the mount" do
    path = Source.mounted_instance_path()

    for value <- ~w(saas demo onprem:untd) do
      assert %Source{kind: :mounted, name: ^path} = Source.for_identity(identity(value))
    end
  end

  test "a source names a built-in by identity and a mount by path" do
    assert Source.to_string(Source.for_identity(identity("ci"))) == "built-in:ci"

    assert Source.to_string(Source.for_identity(identity("saas"))) ==
             Source.mounted_instance_path()
  end

  test "a built-in loads and exposes its sections" do
    built_ins = %{"ci" => F.encode(F.valid_ci())}

    assert {:ok, manager} =
             Manager.load(identity("ci"), built_ins, F.missing_mount())

    assert %Source{kind: :built_in, name: "ci"} = Manager.source(manager)
    assert Manager.database(manager).port == 5432
    assert Manager.nats(manager)
    assert Manager.core(manager)
    assert Manager.dgraph(manager)
  end

  # The check that catches a wrong ConfigMap. It is otherwise completely silent, and its blast
  # radius is the database a component connects to.
  test "an artifact describing another environment is rejected" do
    saas = %{F.valid_ci() | kind: :ENVIRONMENT_KIND_SAAS}

    assert {:error, {:identity_mismatch, _, "demo", "saas"} = err} =
             Manager.load(identity("demo"), %{}, F.mounted(F.encode(saas)))

    message = LoadError.message(err)
    assert message =~ "wrong artifact is mounted"
    assert message =~ "database"
  end

  # The same check, one on-prem customer's artifact in another's deployment.
  test "a different onprem instance is rejected" do
    other = %{F.valid_ci() | kind: :ENVIRONMENT_KIND_ONPREM, instance: "someone-else"}

    assert {:error, err} =
             Manager.load(identity("onprem:untd"), %{}, F.mounted(F.encode(other)))

    message = LoadError.message(err)
    assert message =~ "onprem:untd"
    assert message =~ "onprem:someone-else"
  end

  # Loading and validating are one operation. A committed instance is validated at build; a
  # mounted one has never been seen by this repository's build at all.
  test "an invalid instance is rejected at load and yields nothing" do
    cfg = F.valid_ci()
    broken = %{cfg | database: %{cfg.database | tls_mode: :TLS_MODE_DISABLE}}

    assert {:error, {:invalid, _, violations} = err} =
             Manager.load(identity("ci"), %{"ci" => F.encode(broken)}, F.missing_mount())

    assert Enum.any?(violations, &(&1.code == "DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST"))
    assert LoadError.message(err) =~ "DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST"
  end

  test "an unknown built-in lists what the release carries" do
    assert {:error, err} =
             Manager.load(
               identity("localhost"),
               %{"ci" => F.encode(F.valid_ci())}, F.missing_mount()
             )

    message = LoadError.message(err)
    assert message =~ "localhost"
    assert message =~ "ci"
  end

  # A missing mount is fatal. There is no cached fallback to fall back TO, by construction:
  # nothing retains bytes across a call.
  test "a missing mount is fatal and names the source" do
    assert {:error, {:read, _, _} = err} =
             Manager.load(identity("saas"), %{}, F.missing_mount())

    assert LoadError.message(err) =~ Source.mounted_instance_path()
  end
end
