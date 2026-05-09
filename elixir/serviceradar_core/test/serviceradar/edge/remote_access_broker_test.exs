defmodule ServiceRadar.Edge.RemoteAccessBrokerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessBroker
  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Edge.RemoteAccessSSHSessionCredentials

  @permission RemoteAccessSSHCertificatePolicy.permission()

  defmodule CommandBusStub do
    @moduledoc false

    def send_console_frame(agent_id, frame, opts) do
      send(
        Keyword.fetch!(opts, :required_gateway_node),
        {:send_console_frame, agent_id, frame, opts}
      )

      :ok
    end
  end

  defmodule PubSubStub do
    @moduledoc false

    def subscribe(_session_id), do: :ok
  end

  defmodule CertificateSignerStub do
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

  test "opens generic SSH sessions over the existing console frame path" do
    session = session_fixture()

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          required_gateway_node: self(),
          cols: 132,
          rows: 43}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, opts}
    assert opts[:required_gateway_node] == self()
    assert frame.cols == 132
    assert frame.rows == 43

    assert %{
             "protocol" => "ssh",
             "session_id" => "session-1",
             "agent_id" => "agent-1",
             "gateway_id" => "gateway-1",
             "credential_mode" => "user_present",
             "ssh_host_key_policy" => "skip_verify",
             "target" => %{"host" => "10.0.0.10", "port" => 22},
             "ssh" => %{
               "username" => "root",
               "private_key" => "session-key",
               "certificate" => "session-cert"
             }
           } = Jason.decode!(frame.data)

    assert :ok = RemoteAccessBroker.send_input(pid, "whoami\r")

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "data", data: "whoami\r"},
                    _opts}

    assert :ok = RemoteAccessBroker.resize(pid, 120, 34)

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "resize", cols: 120, rows: 34},
                    _opts}

    RemoteAccessBroker.close(pid, :operator_closed)

    assert_receive {:send_console_frame, "agent-1",
                    %{frame_type: "close", reason: ":operator_closed"}, _opts}
  end

  test "forwards remote-access data and close frames to the owner" do
    session = session_fixture()

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub, pubsub: PubSubStub, required_gateway_node: self()}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"}, _opts}

    send(pid, {:remote_access_frame, %{frame_type: "data", data: "hello"}})
    assert_receive {:remote_access_data, "hello"}

    send(pid, {:remote_access_frame, %{frame_type: "close", reason: "done"}})
    assert_receive {:remote_access_closed, "done"}
  end

  test "opens from a user-present credential grant without persisted session SSH metadata" do
    session = %{
      id: "session-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      metadata: %{}
    }

    assert {:ok, grant} =
             RemoteAccessSSHSessionCredentials.build_user_present_grant(%{
               session_id: "session-1",
               agent_id: "agent-1",
               username: "ubuntu",
               password: "session-password",
               target: %{host: "10.0.0.10", port: 22}
             })

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        grant.broker_opts ++
          [
            command_bus: CommandBusStub,
            pubsub: PubSubStub,
            required_gateway_node: self()
          ]}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}

    assert %{
             "credential_mode" => "user_present",
             "target" => %{"host" => "10.0.0.10", "port" => 22},
             "ssh" => %{"username" => "ubuntu", "password" => "session-password"}
           } = Jason.decode!(frame.data)

    refute inspect(grant.audit) =~ "session-password"
  end

  test "opens from a certificate credential grant without persisted session SSH metadata" do
    session = %{
      id: "session-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      metadata: %{}
    }

    actor = %{id: "user-1", permissions: MapSet.new([@permission])}

    assert {:ok, grant} =
             RemoteAccessSSHSessionCredentials.build_certificate_grant(
               actor,
               %{
                 session_id: "session-1",
                 agent_id: "agent-1",
                 gateway_id: "gateway-1",
                 public_key: "ssh-ed25519 AAAATEST user@workstation",
                 private_key:
                   "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
                 passphrase: "session-passphrase",
                 target: %{device_uid: "device-1", host: "10.0.0.11", port: 2222},
                 allowed_principals: ["ubuntu"]
               },
               signer: CertificateSignerStub,
               test_pid: self()
             )

    assert_receive {:sign_user_certificate, sign_request}
    refute Map.has_key?(sign_request, :private_key)
    refute inspect(sign_request) =~ "session-passphrase"

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        grant.broker_opts ++
          [
            command_bus: CommandBusStub,
            pubsub: PubSubStub,
            required_gateway_node: self()
          ]}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}

    assert %{
             "credential_mode" => "ssh_certificate",
             "target" => %{"device_uid" => "device-1", "host" => "10.0.0.11", "port" => 2222},
             "ssh" => %{
               "username" => "ubuntu",
               "private_key" =>
                 "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
               "passphrase" => "session-passphrase",
               "certificate" => "ssh-ed25519-cert-v01@openssh.com AAAATEST"
             }
           } = Jason.decode!(frame.data)

    refute inspect(grant.ssh_certificate) =~ "OPENSSH PRIVATE KEY"
    refute inspect(grant.audit) =~ "session-passphrase"
  end

  test "merges issued SSH certificate envelopes with user-present session keys" do
    session =
      put_in(session_fixture(), [:metadata, "ssh"], %{
        "username" => "stale-login",
        "private_key" => "session-private-key",
        "passphrase" => "session-passphrase",
        "certificate" => "stale-certificate"
      })

    issued_certificate = %{
      session_id: "session-1",
      agent_id: "agent-1",
      protocol: "ssh",
      credential_mode: "ssh_certificate",
      target: %{"host" => "10.0.0.11", "port" => 2222},
      ssh: %{"username" => "ubuntu", "certificate" => "issued-certificate"}
    }

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        required_gateway_node: self(),
        ssh_certificate: issued_certificate}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}

    assert %{
             "credential_mode" => "ssh_certificate",
             "target" => %{"host" => "10.0.0.11", "port" => 2222},
             "ssh" => %{
               "username" => "ubuntu",
               "private_key" => "session-private-key",
               "passphrase" => "session-passphrase",
               "certificate" => "issued-certificate"
             }
           } = Jason.decode!(frame.data)
  end

  test "rejects SSH certificate envelopes scoped to another agent" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    session = session_fixture()

    issued_certificate = %{
      session_id: "session-1",
      agent_id: "other-agent",
      protocol: "ssh",
      credential_mode: "ssh_certificate",
      target: %{"host" => "10.0.0.11", "port" => 2222},
      ssh: %{"username" => "ubuntu", "certificate" => "issued-certificate"}
    }

    assert {:error, :ssh_certificate_agent_mismatch} =
             RemoteAccessBroker.start_link(session, self(),
               command_bus: CommandBusStub,
               pubsub: PubSubStub,
               required_gateway_node: self(),
               ssh_certificate: issued_certificate
             )

    refute_receive {:send_console_frame, _agent_id, _frame, _opts}
  end

  defp session_fixture do
    %{
      id: "session-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      metadata: %{
        "target" => %{"host" => "10.0.0.10", "port" => 22},
        "ssh" => %{
          "username" => "root",
          "private_key" => "session-key",
          "certificate" => "session-cert"
        }
      }
    }
  end
end
