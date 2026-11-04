defmodule ServiceRadar.NATS.StaticIdentityGrantsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NATS.StaticIdentityGrants

  # Selection of a static grant at the callout is covered through the
  # authorizer in ManagedCertificateAccountTest. This covers reading the file.
  test "a missing file grants nothing and an unparsable one is refused" do
    dir = Path.join(System.tmp_dir!(), "static-users-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert StaticIdentityGrants.load(nil) == {:ok, %{}}
    assert StaticIdentityGrants.load(Path.join(dir, "absent.yaml")) == {:ok, %{}}

    for contents <- [
          ~s(- user: "CN=example"\n  publish: {allow: "not a list"}\n  subscribe: {allow: []}\n),
          "- user: \"CN=example\"\n  publish: {allow: []}\n",
          "- user: \"not a subject\"\n  publish: {allow: []}\n  subscribe: {allow: []}\n",
          "user: not a list\n"
        ] do
      path = Path.join(dir, "invalid.yaml")
      File.write!(path, contents)
      assert StaticIdentityGrants.load(path) == {:error, :invalid_static_users}
    end
  end
end
