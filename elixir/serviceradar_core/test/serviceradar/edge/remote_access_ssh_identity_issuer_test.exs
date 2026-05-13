defmodule ServiceRadar.Edge.RemoteAccessSSHIdentityIssuerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Edge.RemoteAccessSSHIdentityIssuer

  @permission RemoteAccessSSHCertificatePolicy.permission()

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

  test "issues certificates from authoritative Authentik claims" do
    actor = oidc_actor()

    assert {:ok, envelope} =
             RemoteAccessSSHIdentityIssuer.issue(
               actor,
               %{
                 session_id: "session-1",
                 agent_id: "agent-1",
                 public_key: "ssh-ed25519 AAAATEST user@workstation",
                 target: %{device_uid: "device-1", host: "10.0.0.10"},
                 principal_mappings: [
                   %{
                     "source" => "groups",
                     "value" => "linux-admins",
                     "principals" => ["ubuntu", "root"]
                   }
                 ],
                 requested_principals: ["ubuntu"],
                 ttl_seconds: 900
               },
               signer: SignerStub,
               audit_writer: {AuditWriterStub, test_pid: self()},
               test_pid: self(),
               idp_claims: %{"groups" => ["linux-admins", "unrelated"]}
             )

    assert_receive {:sign_user_certificate, sign_request}
    assert_receive {:audit, audit}

    assert sign_request.principals == ["ubuntu"]
    assert sign_request.ttl_seconds == 900
    assert sign_request.key_id == "sr:remote-access:session-1:user-1:agent-1:ssh:device-1"
    assert envelope.ssh["username"] == "ubuntu"
    assert envelope.credential_mode == "ssh_certificate"

    assert audit[:action] == :remote_access_ssh_certificate_issue
    assert audit[:resource_type] == "remote_access_ssh_certificate"
    assert audit[:resource_id] == "session-1"
    assert audit[:severity] == :medium
    assert audit[:details].result == "success"
    assert audit[:details].credential_custody_mode == "short_lived_certificate"
    assert audit[:details].principals == ["ubuntu"]
    refute inspect(audit) =~ "AAAATEST user@workstation"
  end

  test "ignores browser-supplied identity claims" do
    actor = oidc_actor()

    attrs = %{
      session_id: "session-1",
      agent_id: "agent-1",
      public_key: "ssh-ed25519 AAAATEST user@workstation",
      target: %{device_uid: "device-1"},
      claims: %{"groups" => ["linux-admins"]},
      idp_claims: %{"groups" => ["linux-admins"]},
      principal_mappings: [
        %{"source" => "groups", "value" => "linux-admins", "principals" => ["ubuntu"]}
      ],
      requested_principals: ["ubuntu"]
    }

    assert {:error, :ssh_principal_policy_required} =
             RemoteAccessSSHIdentityIssuer.issue(actor, attrs,
               signer: SignerStub,
               audit_writer: {AuditWriterStub, test_pid: self()},
               test_pid: self(),
               idp_claims: %{"groups" => ["auditors"]}
             )

    refute_received {:sign_user_certificate, _request}
    assert_receive {:audit, audit}
    assert audit[:severity] == :high
    assert audit[:details].result == "denied"
    assert audit[:details].failure_reason == "ssh_principal_policy_required"
    refute inspect(audit) =~ "linux-admins"
  end

  test "redacts credential material from denial audit details" do
    attrs = %{
      session_id: "session-1",
      agent_id: "agent-1",
      public_key: "ssh-ed25519 AAAATEST",
      private_key:
        "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----",
      target: %{device_uid: "device-1"},
      allowed_principals: ["ubuntu"]
    }

    assert {:error, :sso_identity_required} =
             RemoteAccessSSHIdentityIssuer.issue(
               %{oidc_actor() | last_auth_method: :password},
               attrs,
               signer: SignerStub,
               audit_writer: {AuditWriterStub, test_pid: self()},
               test_pid: self(),
               idp_claims: %{}
             )

    assert_receive {:audit, audit}
    refute inspect(audit) =~ "OPENSSH PRIVATE KEY"
    refute inspect(audit) =~ "secret"
  end

  test "overlays ServiceRadar actor identity into authoritative claims" do
    actor = oidc_actor()

    assert {:ok, envelope} =
             RemoteAccessSSHIdentityIssuer.issue(
               actor,
               %{
                 session_id: "session-1",
                 agent_id: "agent-1",
                 public_key: "ssh-ed25519 AAAATEST user@workstation",
                 target: %{device_uid: "device-1"},
                 principal_mappings: [
                   %{
                     "source" => "email_domain",
                     "value" => "example.com",
                     "principals" => ["alice"]
                   }
                 ]
               },
               signer: SignerStub,
               audit_writer: {AuditWriterStub, test_pid: self()},
               test_pid: self(),
               idp_claims: %{}
             )

    assert_receive {:sign_user_certificate, sign_request}
    assert_receive {:audit, audit}
    assert audit[:action] == :remote_access_ssh_certificate_issue
    assert sign_request.principals == ["alice"]
    assert envelope.principals == ["alice"]
  end

  test "requires SSO-backed identity by default" do
    actor = %{oidc_actor() | last_auth_method: :password, external_id: nil}

    assert {:error, :sso_identity_required} =
             RemoteAccessSSHIdentityIssuer.issue(
               actor,
               %{
                 session_id: "session-1",
                 agent_id: "agent-1",
                 public_key: "ssh-ed25519 AAAATEST",
                 target: %{device_uid: "device-1"},
                 allowed_principals: ["ubuntu"]
               },
               signer: SignerStub,
               audit_writer: {AuditWriterStub, test_pid: self()},
               test_pid: self(),
               idp_claims: %{}
             )

    refute_received {:sign_user_certificate, _request}
    assert_receive {:audit, audit}
    assert audit[:action] == :remote_access_ssh_certificate_issue
  end

  test "rejects malformed authoritative claims" do
    assert {:error, :invalid_identity_claims} =
             RemoteAccessSSHIdentityIssuer.issue(
               oidc_actor(),
               %{
                 session_id: "session-1",
                 agent_id: "agent-1",
                 public_key: "ssh-ed25519 AAAATEST",
                 target: %{device_uid: "device-1"},
                 allowed_principals: ["ubuntu"]
               },
               signer: SignerStub,
               audit_writer: {AuditWriterStub, test_pid: self()},
               test_pid: self(),
               idp_claims: ["linux-admins"]
             )

    assert_receive {:audit, audit}
    assert audit[:action] == :remote_access_ssh_certificate_issue
  end

  defp oidc_actor do
    %{
      id: "user-1",
      email: "alice@example.com",
      display_name: "Alice Example",
      external_id: "authentik|alice",
      last_auth_method: :oidc,
      permissions: MapSet.new([@permission])
    }
  end
end
