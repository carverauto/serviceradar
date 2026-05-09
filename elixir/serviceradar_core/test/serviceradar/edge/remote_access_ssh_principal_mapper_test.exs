defmodule ServiceRadar.Edge.RemoteAccessSSHPrincipalMapperTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSSHPrincipalMapper

  test "maps Authentik-style groups to SSH principals" do
    claims = %{
      "email" => "operator@example.com",
      "preferred_username" => "operator",
      "groups" => ["linux-admins", "network-readonly"]
    }

    mappings = [
      %{"source" => "groups", "value" => "linux-admins", "principals" => ["root", "ubuntu"]},
      %{"source" => "groups", "value" => "network-readonly", "principals" => ["netops"]},
      %{"source" => "groups", "value" => "unmatched", "principals" => ["nobody"]}
    ]

    assert RemoteAccessSSHPrincipalMapper.resolve(claims, mappings) == [
             "root",
             "ubuntu",
             "netops"
           ]
  end

  test "supports email, email domain, and explicit claim mappings" do
    claims = %{
      "email" => "admin@example.com",
      "ssh_roles" => ["prod-shell", "break-glass"]
    }

    mappings = [
      %{source: :email, value: "admin@example.com", principals: ["admin"]},
      %{source: :email_domain, value: "example.com", principals: "ops\nubuntu"},
      %{source: :claim, claim: :ssh_roles, value: "prod-shell", principals: ["prod"]}
    ]

    assert RemoteAccessSSHPrincipalMapper.resolve(claims, mappings) == [
             "admin",
             "ops",
             "ubuntu",
             "prod"
           ]
  end

  test "filters invalid principals and deduplicates matches" do
    claims = %{"groups" => "linux-admins,linux-admins"}

    mappings = [
      %{
        "source" => "groups",
        "value" => "linux-admins",
        "principals" => ["ubuntu", "ubuntu", "bad principal", "bad:principal", ""]
      }
    ]

    assert RemoteAccessSSHPrincipalMapper.resolve(claims, mappings) == ["ubuntu"]
  end

  test "returns an empty list for missing claims or mappings" do
    assert RemoteAccessSSHPrincipalMapper.resolve(%{}, []) == []
    assert RemoteAccessSSHPrincipalMapper.resolve(nil, []) == []
    assert RemoteAccessSSHPrincipalMapper.resolve(%{"groups" => ["linux-admins"]}, nil) == []
  end
end
