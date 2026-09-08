defmodule ServiceRadar.Edge.RemoteAccessSSHCertificatesTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Security.RateLimiter

  @moduletag :requires_app

  @permission RemoteAccessSSHCertificatePolicy.permission()
  @principal "srp_v1_6d8b1e49fbe24ad487ce2c5c"

  setup do
    on_exit(fn -> :ets.delete_all_objects(RateLimiter.__table__()) end)
    :ets.delete_all_objects(RateLimiter.__table__())
    :ok
  end

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

  defmodule ConfiguredSignerStub do
    @moduledoc false
    @behaviour RemoteAccessSSHCertificates

    @impl true
    def sign_user_certificate(request, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:configured_sign_user_certificate, request})

      {:ok,
       %{
         certificate: "ssh-ed25519-cert-v01@openssh.com CONFIGURED",
         expires_at: ~U[2026-05-09 14:00:00Z],
         fingerprint: "SHA256:configured",
         serial: 84,
         ca_key_id: "ca-configured"
       }}
    end
  end

  test "issues SSH certificate through injected signer after policy authorization" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    attrs = %{
      session_id: "session-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      username: "mfreeman",
      public_key: "ssh-ed25519 AAAATEST user@workstation",
      target: %{device_uid: "device-1", host: "10.0.0.10"},
      accounts: [%{name: "mfreeman", principals: [@principal]}],
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
                      key_id: "sr:remote-access:session-1:user-1:agent-1:ssh:device-1",
                      principals: [@principal],
                      ttl_seconds: 900,
                      audit: %{
                        actor_id: "user-1",
                        agent_id: "agent-1",
                        protocol: "ssh",
                        target_ref: "device-1",
                        ssh_username: "mfreeman"
                      }
                    }}

    assert issued.session_id == "session-1"
    assert issued.agent_id == "agent-1"
    assert issued.gateway_id == "gateway-1"
    assert issued.protocol == "ssh"
    assert issued.credential_mode == "ssh_certificate"

    assert issued.ssh == %{
             "username" => "mfreeman",
             "certificate" => "ssh-ed25519-cert-v01@openssh.com AAAATEST"
           }

    assert issued.key_id == "sr:remote-access:session-1:user-1:agent-1:ssh:device-1"
    assert issued.principals == [@principal]
    assert issued.fingerprint == "SHA256:fingerprint"
    assert issued.serial == 42
    assert issued.ca_key_id == "ca-main"

    assert issued.audit == %{
             actor_id: "user-1",
             agent_id: "agent-1",
             gateway_id: "gateway-1",
             protocol: "ssh",
             target_ref: "device-1",
             principals: [@principal],
             ssh_username: "mfreeman",
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

  test "uses configured signer when no per-call signer is provided" do
    previous = Application.get_env(:serviceradar_core, RemoteAccessSSHCertificates)

    Application.put_env(:serviceradar_core, RemoteAccessSSHCertificates,
      signer: ConfiguredSignerStub,
      test_pid: self()
    )

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, RemoteAccessSSHCertificates)
      else
        Application.put_env(:serviceradar_core, RemoteAccessSSHCertificates, previous)
      end
    end)

    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:ok, issued} =
             RemoteAccessSSHCertificates.issue(actor, %{
               session_id: "session-1",
               agent_id: "agent-1",
               username: "mfreeman",
               public_key: "ssh-ed25519 AAAATEST",
               target: %{device_uid: "device-1"},
               accounts: [%{name: "mfreeman", principals: [@principal]}]
             })

    assert_receive {:configured_sign_user_certificate,
                    %{key_id: "sr:remote-access:session-1:user-1:agent-1:ssh:device-1"}}

    assert issued.ssh["certificate"] == "ssh-ed25519-cert-v01@openssh.com CONFIGURED"
    assert issued.ca_key_id == "ca-configured"
  end

  test "returns signer errors without building an issued envelope" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:error, :signer_failed} =
             RemoteAccessSSHCertificates.issue(
               actor,
               %{
                 session_id: "session-1",
                 agent_id: "agent-1",
                 username: "mfreeman",
                 public_key: "ssh-ed25519 AAAATEST",
                 target: %{device_uid: "device-1"},
                 accounts: [%{name: "mfreeman", principals: [@principal]}]
               },
               signer: ErrorSignerStub
             )
  end

  test "rate limits SSH certificate issuance per actor before signing" do
    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    attrs = %{
      session_id: "session-1",
      agent_id: "agent-1",
      username: "mfreeman",
      public_key: "ssh-ed25519 AAAATEST",
      target: %{device_uid: "device-1"},
      accounts: [%{name: "mfreeman", principals: [@principal]}]
    }

    assert {:ok, _issued} =
             RemoteAccessSSHCertificates.issue(actor, attrs,
               signer: SignerStub,
               test_pid: self(),
               rate_limit: [limit: 1, window_seconds: 60]
             )

    assert_receive {:sign_user_certificate, _request}

    assert {:error, {:ssh_certificate_rate_limited, retry_after}} =
             RemoteAccessSSHCertificates.issue(actor, Map.put(attrs, :session_id, "session-2"),
               signer: SignerStub,
               test_pid: self(),
               rate_limit: [limit: 1, window_seconds: 60]
             )

    assert retry_after >= 1
    refute_receive {:sign_user_certificate, _request}
  end
end
