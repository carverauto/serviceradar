defmodule ServiceRadar.Edge.RemoteAccessSSHSessionCredentialsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Edge.RemoteAccessSSHSessionCredentials

  @moduletag :requires_app

  @permission RemoteAccessSSHCertificatePolicy.permission()
  @principal "srp_v1_6d8b1e49fbe24ad487ce2c5c"

  defmodule SignerStub do
    @moduledoc false
    @behaviour RemoteAccessSSHCertificates

    @impl true
    def sign_user_certificate(request, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:sign_user_certificate, request})

      {:ok,
       %{
         certificate: "ssh-ed25519-cert-v01@openssh.com AAAATEST",
         expires_at: ~U[2026-05-09 13:00:00Z],
         fingerprint: "SHA256:fingerprint",
         serial: 42,
         ca_key_id: "ca-main"
       }}
    end
  end

  defmodule AuditWriterStub do
    @moduledoc false

    def write_async(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:audit, opts})
      :ok
    end
  end

  test "builds key-based user-present broker options without certificate issuance" do
    assert {:ok, grant} =
             RemoteAccessSSHSessionCredentials.build_user_present_grant(%{
               session_id: "session-1",
               agent_id: "agent-1",
               username: "ubuntu",
               private_key: "session-private-key",
               passphrase: "session-passphrase",
               target: %{device_uid: "device-1", host: "10.0.0.10", port: 2222}
             })

    assert grant.broker_opts == [
             metadata: %{
               "ssh" => %{
                 "username" => "ubuntu",
                 "private_key" => "session-private-key",
                 "passphrase" => "session-passphrase"
               },
               "target" => %{
                 "device_uid" => "device-1",
                 "host" => "10.0.0.10",
                 "port" => 2222
               }
             },
             credential_mode: "user_present"
           ]

    assert grant.ssh_certificate == nil
    assert grant.audit.credential_kind == "private_key"
    assert grant.audit.target_ref == "device-1"
    refute inspect(grant.audit) =~ "session-private-key"
    refute inspect(grant.audit) =~ "session-passphrase"
  end

  test "builds password-based user-present broker options without persisting password" do
    assert {:ok, grant} =
             RemoteAccessSSHSessionCredentials.build_user_present_grant(%{
               session_id: "session-1",
               agent_id: "agent-1",
               username: "ubuntu",
               password: "session-password",
               target: %{host: "10.0.0.10"}
             })

    assert grant.broker_opts == [
             metadata: %{
               "ssh" => %{"username" => "ubuntu", "password" => "session-password"},
               "target" => %{"host" => "10.0.0.10"}
             },
             credential_mode: "user_present"
           ]

    assert grant.audit.credential_kind == "password"
    assert grant.audit.target_ref == "10.0.0.10"
    refute inspect(grant.audit) =~ "session-password"
  end

  test "fails closed without username or user-present credential material" do
    assert {:error, :ssh_username_required} =
             RemoteAccessSSHSessionCredentials.build_user_present_grant(%{
               private_key: "session-private-key"
             })

    assert {:error, :session_credential_required} =
             RemoteAccessSSHSessionCredentials.build_user_present_grant(%{
               username: "ubuntu"
             })
  end

  test "builds broker options from a user-present key and issued certificate" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    attrs = %{
      session_id: "session-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      username: "mfreeman",
      public_key: "ssh-ed25519 AAAATEST user@workstation",
      private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
      passphrase: "session-passphrase",
      target: %{device_uid: "device-1", host: "10.0.0.10"},
      accounts: [%{name: "mfreeman", principals: [@principal]}],
      claims: %{"groups" => ["linux-admins"]},
      principal_mappings: [
        %{"source" => "groups", "value" => "linux-admins", "principals" => [@principal]}
      ],
      ttl_seconds: 900
    }

    assert {:ok, grant} =
             RemoteAccessSSHSessionCredentials.build_certificate_grant(actor, attrs,
               signer: SignerStub,
               test_pid: self()
             )

    assert_receive {:sign_user_certificate, sign_request}
    refute Map.has_key?(sign_request, :private_key)
    refute inspect(sign_request) =~ "session-passphrase"

    assert grant.broker_opts[:metadata] == %{
             "ssh" => %{
               "private_key" =>
                 "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
               "passphrase" => "session-passphrase"
             }
           }

    assert grant.broker_opts[:ssh_certificate].ssh == %{
             "username" => "mfreeman",
             "certificate" => "ssh-ed25519-cert-v01@openssh.com AAAATEST"
           }

    refute inspect(grant.ssh_certificate) =~ "OPENSSH PRIVATE KEY"
    refute inspect(grant.audit) =~ "session-passphrase"

    assert grant.audit.credential_custody_mode == "short_lived_certificate"
    assert grant.audit.credential_mode == "ssh_certificate"
    assert grant.audit.session_id == "session-1"
  end

  test "builds identity certificate grant from authoritative SSO claims" do
    actor = %{
      id: "user-1",
      email: "alice@example.com",
      external_id: "authentik|alice",
      last_auth_method: :oidc,
      permissions: MapSet.new([@permission])
    }

    attrs = %{
      session_id: "session-1",
      agent_id: "agent-1",
      username: "mfreeman",
      public_key: "ssh-ed25519 AAAATEST user@workstation",
      private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
      claims: %{"groups" => ["browser-admins"]},
      target: %{device_uid: "device-1", host: "10.0.0.10"},
      accounts: [%{name: "mfreeman", principals: [@principal]}],
      principal_mappings: [
        %{"source" => "groups", "value" => "linux-admins", "principals" => [@principal]}
      ]
    }

    assert {:ok, grant} =
             RemoteAccessSSHSessionCredentials.build_identity_certificate_grant(
               actor,
               attrs,
               signer: SignerStub,
               audit_writer: {AuditWriterStub, test_pid: self()},
               test_pid: self(),
               idp_claims: %{
                 "groups" => ["linux-admins"],
                 "service_radar_auth_method" => "oidc"
               }
             )

    assert_receive {:sign_user_certificate, sign_request}
    assert_receive {:audit, audit}
    assert audit[:action] == :remote_access_ssh_certificate_issue
    assert sign_request.principals == [@principal]
    refute inspect(sign_request) =~ "OPENSSH PRIVATE KEY"
    refute inspect(sign_request) =~ "browser-admins"

    assert grant.broker_opts[:ssh_certificate].credential_mode == "ssh_certificate"
    assert grant.broker_opts[:ssh_certificate].ssh["username"] == "mfreeman"
    assert grant.broker_opts[:metadata]["ssh"]["private_key"] =~ "OPENSSH PRIVATE KEY"
    refute inspect(grant.audit) =~ "OPENSSH PRIVATE KEY"
    assert grant.audit.credential_custody_mode == "short_lived_certificate"
    assert grant.audit.credential_mode == "ssh_certificate"
  end

  test "fails closed without a session private key" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:error, :session_private_key_required} =
             RemoteAccessSSHSessionCredentials.build_certificate_grant(
               actor,
               %{
                 session_id: "session-1",
                 agent_id: "agent-1",
                 username: "mfreeman",
                 public_key: "ssh-ed25519 AAAATEST",
                 target: %{device_uid: "device-1"},
                 accounts: [%{name: "mfreeman", principals: [@principal]}]
               },
               signer: SignerStub
             )
  end
end
