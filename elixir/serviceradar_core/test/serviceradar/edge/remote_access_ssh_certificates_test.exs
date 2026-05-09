defmodule ServiceRadar.Edge.RemoteAccessSSHCertificatesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates

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

  defmodule ErrorSignerStub do
    @moduledoc false
    @behaviour RemoteAccessSSHCertificates

    @impl true
    def sign_user_certificate(_request, _opts), do: {:error, :signer_failed}
  end

  test "issues SSH certificate through injected signer after policy authorization" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    attrs = %{
      session_id: "session-1",
      public_key: "ssh-ed25519 AAAATEST user@workstation",
      target: %{device_uid: "device-1", host: "10.0.0.10"},
      allowed_principals: ["root", "ubuntu"],
      requested_principals: ["ubuntu"],
      ttl_seconds: 900
    }

    assert {:ok, issued} =
             RemoteAccessSSHCertificates.issue(actor, attrs,
               signer: SignerStub,
               test_pid: self()
             )

    assert_receive {:sign_user_certificate,
                    %{
                      public_key: "ssh-ed25519 AAAATEST user@workstation",
                      key_id: "sr:remote-access:session-1:user-1:device-1",
                      principals: ["ubuntu"],
                      ttl_seconds: 900,
                      audit: %{actor_id: "user-1", target_ref: "device-1", ssh_username: "ubuntu"}
                    }}

    assert issued.session_id == "session-1"
    assert issued.credential_mode == "ssh_certificate"

    assert issued.ssh == %{
             "username" => "ubuntu",
             "certificate" => "ssh-ed25519-cert-v01@openssh.com AAAATEST"
           }

    assert issued.key_id == "sr:remote-access:session-1:user-1:device-1"
    assert issued.principals == ["ubuntu"]
    assert issued.fingerprint == "SHA256:fingerprint"
    assert issued.serial == 42
    assert issued.ca_key_id == "ca-main"

    assert issued.audit == %{
             actor_id: "user-1",
             target_ref: "device-1",
             principals: ["ubuntu"],
             ssh_username: "ubuntu",
             ttl_seconds: 900,
             permission: @permission,
             certificate_fingerprint: "SHA256:fingerprint",
             certificate_serial: 42,
             ca_key_id: "ca-main",
             expires_at: ~U[2026-05-09 13:00:00Z]
           }
  end

  test "fails closed without signer or when policy rejects request" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:error, :ssh_certificate_signer_unavailable} =
             RemoteAccessSSHCertificates.issue(actor, %{})

    assert {:error, :forbidden} =
             RemoteAccessSSHCertificates.issue(
               %{id: "user-1", permissions: MapSet.new()},
               %{session_id: "session-1"},
               signer: SignerStub
             )
  end

  test "returns signer errors without building an issued envelope" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:error, :signer_failed} =
             RemoteAccessSSHCertificates.issue(
               actor,
               %{
                 session_id: "session-1",
                 public_key: "ssh-ed25519 AAAATEST",
                 target: %{device_uid: "device-1"},
                 allowed_principals: ["root"]
               },
               signer: ErrorSignerStub
             )
  end
end
