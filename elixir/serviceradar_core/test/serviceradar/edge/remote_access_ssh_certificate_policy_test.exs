defmodule ServiceRadar.Edge.RemoteAccessSSHCertificatePolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Identity.RBAC.Catalog

  @permission RemoteAccessSSHCertificatePolicy.permission()
  @mfreeman_principal "srp_v1_6d8b1e49fbe24ad487ce2c5c"
  @mfreeman_backup_principal "srp_v1_91c5f16df8aa4d90a6db2ed7"
  @deploy_principal "srp_v1_7368ed9199dd46b489fe4f16"

  test "keeps the Unix login username separate from account-bound opaque principals" do
    actor = actor()

    assert {:ok, request} =
             RemoteAccessSSHCertificatePolicy.authorize(actor, %{
               "session_id" => "session-1",
               "agent_id" => "agent-1",
               "gateway_id" => "gateway-1",
               "username" => "mfreeman",
               "public_key" => "ssh-ed25519 AAAATEST user@workstation",
               "target" => %{"device_uid" => "device-1", "host" => "10.0.0.10"},
               "accounts" => [
                 %{
                   "name" => "mfreeman",
                   "principals" => [@mfreeman_principal, @mfreeman_backup_principal]
                 },
                 %{"name" => "deploy", "principals" => [@deploy_principal]}
               ],
               "claims" => %{"groups" => ["linux-admins"]},
               "principal_mappings" => [
                 %{
                   "source" => "groups",
                   "value" => "linux-admins",
                   "principals" => [@mfreeman_backup_principal, @deploy_principal]
                 }
               ],
               "ttl_seconds" => 900
             })

    assert request.session_id == "session-1"
    assert request.agent_id == "agent-1"
    assert request.gateway_id == "gateway-1"
    assert request.protocol == "ssh"
    assert request.ssh_username == "mfreeman"
    assert request.principals == [@mfreeman_backup_principal]
    assert request.ttl_seconds == 900
    assert request.credential_mode == "ssh_certificate"
    assert request.key_id == "sr:remote-access:session-1:user-1:agent-1:ssh:device-1"

    assert request.audit == %{
             actor_id: "user-1",
             agent_id: "agent-1",
             gateway_id: "gateway-1",
             protocol: "ssh",
             target_ref: "device-1",
             principals: [@mfreeman_backup_principal],
             ssh_username: "mfreeman",
             ttl_seconds: 900,
             permission: @permission
           }
  end

  test "uses every principal for the exact account when no IdP mapping is configured" do
    assert {:ok, request} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), %{
               session_id: "session-1",
               agent_id: "agent-1",
               username: "mfreeman",
               public_key: "ssh-ed25519 AAAATEST",
               target: %{host: "router.example"},
               accounts: [
                 %{
                   name: "mfreeman",
                   principals: [@mfreeman_principal, @mfreeman_backup_principal]
                 },
                 %{name: "deploy", principals: [@deploy_principal]}
               ]
             })

    assert request.ssh_username == "mfreeman"
    assert request.principals == [@mfreeman_principal, @mfreeman_backup_principal]
    assert request.ttl_seconds == 3_600
    refute @deploy_principal in request.principals
  end

  test "ignores caller-supplied principal selections" do
    assert {:ok, request} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), %{
               session_id: "session-1",
               agent_id: "agent-1",
               username: "mfreeman",
               public_key: "ssh-ed25519 AAAATEST",
               target: %{device_uid: "device-1"},
               accounts: [%{name: "mfreeman", principals: [@mfreeman_principal]}],
               allowed_principals: [@deploy_principal],
               principals: [@deploy_principal],
               requested_principals: [@deploy_principal]
             })

    assert request.ssh_username == "mfreeman"
    assert request.principals == [@mfreeman_principal]
  end

  test "rejects unauthorized actors, root, malformed, and unmapped login usernames" do
    attrs = base_attrs()

    assert {:error, :forbidden} =
             RemoteAccessSSHCertificatePolicy.authorize(
               %{id: "user-1", permissions: MapSet.new()},
               attrs
             )

    assert {:error, :ssh_username_denied} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), %{attrs | username: "root"})

    assert {:error, :ssh_username_denied} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), %{attrs | username: "Bad User"})

    assert {:error, :ssh_username_denied} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), %{attrs | username: "deploy"})
  end

  test "denies when IdP mappings do not grant the selected account or are malformed" do
    attrs =
      base_attrs()
      |> Map.put(:claims, %{"groups" => ["auditors"]})
      |> Map.put(:principal_mappings, [
        %{
          "source" => "groups",
          "value" => "linux-admins",
          "principals" => [@mfreeman_principal]
        }
      ])

    assert {:error, :ssh_principal_denied} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), attrs)

    assert {:error, :ssh_principal_denied} =
             RemoteAccessSSHCertificatePolicy.authorize(
               actor(),
               Map.put(base_attrs(), :principal_mappings, ["malformed-mapping"])
             )
  end

  test "fails closed without a valid non-root account-to-opaque-principal mapping" do
    legacy_attrs =
      base_attrs()
      |> Map.delete(:accounts)
      |> Map.put(:allowed_principals, ["mfreeman"])
      |> Map.put(:requested_principals, ["mfreeman"])

    assert {:error, :ssh_principal_policy_required} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), legacy_attrs)

    for accounts <- [
          [%{name: "root", principals: [@mfreeman_principal]}],
          [%{name: "mfreeman", principals: ["mfreeman"]}],
          [%{name: "mfreeman", principals: [@mfreeman_principal, @mfreeman_principal]}],
          [
            %{name: "mfreeman", principals: [@mfreeman_principal]},
            %{name: "mfreeman", principals: [@mfreeman_backup_principal]}
          ],
          [
            %{name: "mfreeman", principals: [@mfreeman_principal]},
            %{name: "deploy", principals: [@mfreeman_principal]}
          ]
        ] do
      assert {:error, :ssh_principal_policy_required} =
               RemoteAccessSSHCertificatePolicy.authorize(
                 actor(),
                 Map.put(legacy_attrs, :accounts, accounts)
               )
    end
  end

  test "rejects missing target, missing username, and ttl over maximum" do
    attrs = base_attrs()

    assert {:error, :target_required} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), Map.delete(attrs, :target))

    assert {:error, :ssh_username_required} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), Map.delete(attrs, :username))

    assert {:error, :ttl_exceeds_maximum} =
             RemoteAccessSSHCertificatePolicy.authorize(
               actor(),
               Map.put(attrs, :ttl_seconds, 28_801)
             )
  end

  test "requires agent scope and rejects non-SSH certificate protocols" do
    attrs = base_attrs()

    assert {:error, :agent_id_required} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), Map.delete(attrs, :agent_id))

    assert {:error, :unsupported_protocol} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), Map.put(attrs, :protocol, "rdp"))
  end

  test "rejects oversized certificate request fields and policies" do
    attrs = base_attrs()

    assert {:error, :invalid_size} =
             RemoteAccessSSHCertificatePolicy.authorize(
               actor(),
               Map.put(attrs, :public_key, String.duplicate("k", 16_385))
             )

    assert {:error, :invalid_size} =
             RemoteAccessSSHCertificatePolicy.authorize(
               actor(),
               Map.put(attrs, :target, %{host: String.duplicate("h", 513)})
             )

    assert {:error, :invalid_size} =
             RemoteAccessSSHCertificatePolicy.authorize(
               actor(),
               Map.put(attrs, :target, %{host: "router.example", port: 70_000})
             )

    accounts =
      Enum.map(1..129, fn index ->
        %{name: "user#{index}", principals: [@mfreeman_principal]}
      end)

    assert {:error, :invalid_size} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), %{attrs | accounts: accounts})

    principals =
      Enum.map(1..17, fn index ->
        "srp_v1_" <> String.pad_leading(Integer.to_string(index), 20, "0")
      end)

    assert {:error, :invalid_size} =
             RemoteAccessSSHCertificatePolicy.authorize(actor(), %{
               attrs
               | accounts: [%{name: "mfreeman", principals: principals}]
             })
  end

  test "catalog exposes SSH remote access as an admin-only permission" do
    assert @permission in Catalog.permission_keys()
    assert MapSet.member?(Catalog.permissions_for_role(:admin), @permission)
    refute MapSet.member?(Catalog.permissions_for_role(:operator), @permission)
  end

  defp actor, do: %{id: "user-1", permissions: MapSet.new([@permission])}

  defp base_attrs do
    %{
      session_id: "session-1",
      agent_id: "agent-1",
      username: "mfreeman",
      public_key: "ssh-ed25519 AAAATEST",
      target: %{device_uid: "device-1"},
      accounts: [%{name: "mfreeman", principals: [@mfreeman_principal]}]
    }
  end
end
