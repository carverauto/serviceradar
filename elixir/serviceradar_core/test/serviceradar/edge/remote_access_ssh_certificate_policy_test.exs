defmodule ServiceRadar.Edge.RemoteAccessSSHCertificatePolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Identity.RBAC.Catalog

  @permission RemoteAccessSSHCertificatePolicy.permission()

  test "authorizes bounded SSH certificate request" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:ok, request} =
             RemoteAccessSSHCertificatePolicy.authorize(actor, %{
               "session_id" => "session-1",
               "agent_id" => "agent-1",
               "gateway_id" => "gateway-1",
               "public_key" => "ssh-ed25519 AAAATEST user@workstation",
               "target" => %{"device_uid" => "device-1", "host" => "10.0.0.10"},
               "allowed_principals" => ["root", "ubuntu"],
               "requested_principals" => ["ubuntu", "nobody"],
               "ttl_seconds" => 900
             })

    assert request.session_id == "session-1"
    assert request.agent_id == "agent-1"
    assert request.gateway_id == "gateway-1"
    assert request.protocol == "ssh"
    assert request.public_key == "ssh-ed25519 AAAATEST user@workstation"
    assert request.principals == ["ubuntu"]
    assert request.ssh_username == "ubuntu"
    assert request.ttl_seconds == 900
    assert request.credential_mode == "ssh_certificate"
    assert request.key_id == "sr:remote-access:session-1:user-1:agent-1:ssh:device-1"

    assert request.audit == %{
             actor_id: "user-1",
             agent_id: "agent-1",
             gateway_id: "gateway-1",
             protocol: "ssh",
             target_ref: "device-1",
             principals: ["ubuntu"],
             ssh_username: "ubuntu",
             ttl_seconds: 900,
             permission: @permission
           }
  end

  test "defaults to allowed principals and bounded default ttl" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:ok, request} =
             RemoteAccessSSHCertificatePolicy.authorize(actor, %{
               session_id: "session-1",
               agent_id: "agent-1",
               public_key: "ssh-ed25519 AAAATEST",
               target: %{host: "router.example"},
               allowed_principals: "root, ubuntu\nadmin"
             })

    assert request.principals == ["root", "ubuntu", "admin"]
    assert request.ssh_username == "root"
    assert request.ttl_seconds == 3_600
    assert request.key_id == "sr:remote-access:session-1:user-1:agent-1:ssh:router.example"
  end

  test "rejects unauthorized actors and denied principals" do
    attrs = %{
      session_id: "session-1",
      agent_id: "agent-1",
      public_key: "ssh-ed25519 AAAATEST",
      target: %{device_uid: "device-1"},
      allowed_principals: ["root"]
    }

    assert {:error, :forbidden} =
             RemoteAccessSSHCertificatePolicy.authorize(
               %{id: "user-1", permissions: MapSet.new()},
               attrs
             )

    assert {:error, :ssh_principal_denied} =
             RemoteAccessSSHCertificatePolicy.authorize(
               %{id: "user-1", permissions: MapSet.new([@permission])},
               Map.put(attrs, :requested_principals, ["ubuntu"])
             )
  end

  test "rejects missing target, missing principal policy, and ttl over maximum" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:error, :target_required} =
             RemoteAccessSSHCertificatePolicy.authorize(actor, %{
               session_id: "session-1",
               agent_id: "agent-1",
               public_key: "ssh-ed25519 AAAATEST",
               allowed_principals: ["root"]
             })

    assert {:error, :ssh_principal_policy_required} =
             RemoteAccessSSHCertificatePolicy.authorize(actor, %{
               session_id: "session-1",
               agent_id: "agent-1",
               public_key: "ssh-ed25519 AAAATEST",
               target: %{device_uid: "device-1"}
             })

    assert {:error, :ttl_exceeds_maximum} =
             RemoteAccessSSHCertificatePolicy.authorize(actor, %{
               session_id: "session-1",
               agent_id: "agent-1",
               public_key: "ssh-ed25519 AAAATEST",
               target: %{device_uid: "device-1"},
               allowed_principals: ["root"],
               ttl_seconds: 28_801
             })
  end

  test "requires agent scope and rejects non-SSH certificate protocols" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:error, :agent_id_required} =
             RemoteAccessSSHCertificatePolicy.authorize(actor, %{
               session_id: "session-1",
               public_key: "ssh-ed25519 AAAATEST",
               target: %{device_uid: "device-1"},
               allowed_principals: ["root"]
             })

    assert {:error, :unsupported_protocol} =
             RemoteAccessSSHCertificatePolicy.authorize(actor, %{
               session_id: "session-1",
               agent_id: "agent-1",
               protocol: "rdp",
               public_key: "ssh-ed25519 AAAATEST",
               target: %{device_uid: "device-1"},
               allowed_principals: ["root"]
             })
  end

  test "catalog exposes SSH remote access as an admin-only permission" do
    assert @permission in Catalog.permission_keys()
    assert MapSet.member?(Catalog.permissions_for_role(:admin), @permission)
    refute MapSet.member?(Catalog.permissions_for_role(:operator), @permission)
  end
end
