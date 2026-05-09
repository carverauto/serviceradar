defmodule ServiceRadar.Edge.RemoteAccessSSHSessionCredentialsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Edge.RemoteAccessSSHSessionCredentials

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

  test "builds broker options from a user-present key and issued certificate" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    attrs = %{
      session_id: "session-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      public_key: "ssh-ed25519 AAAATEST user@workstation",
      private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
      passphrase: "session-passphrase",
      target: %{device_uid: "device-1", host: "10.0.0.10"},
      claims: %{"groups" => ["linux-admins"]},
      principal_mappings: [
        %{"source" => "groups", "value" => "linux-admins", "principals" => ["ubuntu"]}
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
             "username" => "ubuntu",
             "certificate" => "ssh-ed25519-cert-v01@openssh.com AAAATEST"
           }

    refute inspect(grant.ssh_certificate) =~ "OPENSSH PRIVATE KEY"
    refute inspect(grant.audit) =~ "session-passphrase"

    assert grant.audit.credential_custody_mode == "user_present"
    assert grant.audit.credential_mode == "ssh_certificate"
    assert grant.audit.session_id == "session-1"
  end

  test "fails closed without a session private key" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:error, :session_private_key_required} =
             RemoteAccessSSHSessionCredentials.build_certificate_grant(
               actor,
               %{
                 session_id: "session-1",
                 agent_id: "agent-1",
                 public_key: "ssh-ed25519 AAAATEST",
                 target: %{device_uid: "device-1"},
                 allowed_principals: ["ubuntu"]
               },
               signer: SignerStub
             )
  end
end
