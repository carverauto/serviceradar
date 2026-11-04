defmodule ServiceRadar.NATS.StaticIdentityGrantsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NATS.StaticIdentityGrants

  # Selection of a static grant at the callout is covered through the
  # authorizer in ManagedCertificateAccountTest. This covers reading the file,
  # and selecting the same grant from the subject the broker lists.
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

  # The hub scan knows a session's certificate only by the subject NATS lists,
  # and disconnects a session whose grant is not the one its certificate gets
  # now. A different selection here would disconnect every session the
  # callout just granted. Each listed subject is what nats-server 2.14 (Go
  # pkix.Name.String) prints for the certificate beside it.
  test "a listed subject selects the grant its certificate's DER selects" do
    {:ok, grants} =
      StaticIdentityGrants.parse("""
      - user: "CN=example-core,OU=Kubernetes,O=ExampleOrg,L=Example City,ST=EX,C=US"
        publish: {allow: ["metrics.core.>"]}
        subscribe: {allow: ["_INBOX.>"]}
      - user: "CN=example-web,OU=Kubernetes,OU=Platform,O=ExampleOrg"
        publish: {allow: ["metrics.web.>"]}
        subscribe: {allow: ["_INBOX.>"]}
      - user: "CN=example+tools,O=ExampleOrg"
        publish: {allow: ["metrics.tools.>"]}
        subscribe: {allow: ["_INBOX.>"]}
      """)

    for {attributes, listed} <- [
          {[
             c: "US",
             st: "EX",
             l: "Example City",
             o: "ExampleOrg",
             ou: "Kubernetes",
             cn: "example-core"
           ], "CN=example-core,OU=Kubernetes,O=ExampleOrg,L=Example City,ST=EX,C=US"},
          {[o: "ExampleOrg", ou: "Kubernetes", ou: "Platform", cn: "example-web"],
           "CN=example-web,OU=Kubernetes+OU=Platform,O=ExampleOrg"},
          {[o: "ExampleOrg", cn: "example+tools"], "CN=example\\+tools,O=ExampleOrg"}
        ] do
      der = subject_certificate(attributes)
      selected = StaticIdentityGrants.grant(grants, "core", der)

      assert %{publish: [_]} = selected
      assert StaticIdentityGrants.presented_grant(grants, "core", listed) == selected
      assert StaticIdentityGrants.presented_grant(grants, "agent", listed) == nil
    end
  end

  @oids %{
    c: {2, 5, 4, 6},
    st: {2, 5, 4, 8},
    l: {2, 5, 4, 7},
    o: {2, 5, 4, 10},
    ou: {2, 5, 4, 11},
    cn: {2, 5, 4, 3}
  }

  defp subject_certificate(attributes) do
    %{cert: root, key: key} = :public_key.pkix_test_root_cert(~c"synthetic root", [])
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(root, :otp)

    rdns =
      Enum.map(attributes, fn
        {:c, value} -> [{:AttributeTypeAndValue, @oids.c, String.to_charlist(value)}]
        {type, value} -> [{:AttributeTypeAndValue, Map.fetch!(@oids, type), {:utf8String, value}}]
      end)

    tbs
    |> put_elem(4, {:rdnSequence, rdns})
    |> put_elem(6, {:rdnSequence, rdns})
    |> :public_key.pkix_sign(key)
  end
end
