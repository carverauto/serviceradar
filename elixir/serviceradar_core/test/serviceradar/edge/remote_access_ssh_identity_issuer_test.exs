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
               test_pid: self(),
               idp_claims: %{"groups" => ["linux-admins", "unrelated"]}
             )

    assert_receive {:sign_user_certificate, sign_request}
    assert sign_request.principals == ["ubuntu"]
    assert sign_request.ttl_seconds == 900
    assert sign_request.key_id == "sr:remote-access:session-1:user-1:agent-1:ssh:device-1"
    assert envelope.ssh["username"] == "ubuntu"
    assert envelope.credential_mode == "ssh_certificate"
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
               test_pid: self(),
               idp_claims: %{"groups" => ["auditors"]}
             )

    refute_received {:sign_user_certificate, _request}
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
               test_pid: self(),
               idp_claims: %{}
             )

    assert_receive {:sign_user_certificate, sign_request}
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
               test_pid: self(),
               idp_claims: %{}
             )

    refute_received {:sign_user_certificate, _request}
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
               test_pid: self(),
               idp_claims: ["linux-admins"]
             )
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
