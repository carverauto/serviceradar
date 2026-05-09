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

  defmodule AuditWriterStub do
    @moduledoc false

    def write_async(opts) do
      send(opts[:actor].test_pid, {:audit, opts})
      :ok
    end
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
          audit_writer: AuditWriterStub,
          audit_actor: audit_actor(),
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

    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened
    assert open_audit[:resource_id] == "session-1"
    assert open_audit[:details].credential_mode == "user_present"
    assert open_audit[:details].target == %{"host" => "10.0.0.10", "port" => 22}
    refute inspect(open_audit) =~ "session-key"
    refute inspect(open_audit) =~ "session-cert"

    assert :ok = RemoteAccessBroker.send_input(pid, "whoami\r")

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "data", data: "whoami\r"},
                    _opts}

    assert_receive {:audit, input_audit}
    assert input_audit[:action] == :remote_access_session_input
    assert input_audit[:details].input_bytes == 7
    refute inspect(input_audit) =~ "whoami"

    assert :ok = RemoteAccessBroker.resize(pid, 120, 34)

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "resize", cols: 120, rows: 34},
                    _opts}

    assert_receive {:audit, resize_audit}
    assert resize_audit[:action] == :remote_access_session_resized
    assert resize_audit[:details].cols == 120
    assert resize_audit[:details].rows == 34

    RemoteAccessBroker.close(pid, :operator_closed)

    assert_receive {:send_console_frame, "agent-1",
                    %{frame_type: "close", reason: ":operator_closed"}, _opts}

    assert_receive {:audit, close_audit}
    assert close_audit[:action] == :remote_access_session_close_requested
    assert close_audit[:details].close_reason == "operator_closed"
  end

  test "forwards remote-access data and close frames to the owner" do
    session = session_fixture()

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          audit_writer: AuditWriterStub,
          audit_actor: audit_actor(),
          required_gateway_node: self()}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"}, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened

    send(pid, {:remote_access_frame, %{agent_id: "agent-1", frame_type: "data", data: "hello"}})
    assert_receive {:remote_access_data, "hello"}

    send(pid, {:remote_access_frame, %{agent_id: "agent-1", frame_type: "close", reason: "done"}})
    assert_receive {:remote_access_closed, "done"}
    assert_receive {:audit, closed_audit}
    assert closed_audit[:action] == :remote_access_session_closed
    assert closed_audit[:details].close_reason == "done"
  end

  test "ignores remote-access frames from agents that do not own the session" do
    session = session_fixture()

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          audit_writer: AuditWriterStub,
          audit_actor: audit_actor(),
          required_gateway_node: self()}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"}, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened

    send(
      pid,
      {:remote_access_frame, %{agent_id: "agent-2", frame_type: "data", data: "intrusion"}}
    )

    send(pid, {:remote_access_frame, %{frame_type: "data", data: "missing-agent-id"}})

    send(
      pid,
      {:remote_access_frame, %{agent_id: "agent-2", frame_type: "close", reason: "wrong-agent"}}
    )

    refute_receive {:remote_access_data, _data}, 50
    refute_receive {:remote_access_closed, _reason}, 50

    send(pid, {:remote_access_frame, %{agent_id: "agent-1", frame_type: "data", data: "owned"}})
    assert_receive {:remote_access_data, "owned"}

    send(pid, {:remote_access_frame, %{agent_id: "agent-1", frame_type: "close", reason: "done"}})
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
            audit_writer: AuditWriterStub,
            audit_actor: audit_actor(),
            required_gateway_node: self()
          ]}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened

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
            audit_writer: AuditWriterStub,
            audit_actor: audit_actor(),
            required_gateway_node: self()
          ]}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened

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
        audit_writer: AuditWriterStub,
        audit_actor: audit_actor(),
        required_gateway_node: self(),
        ssh_certificate: issued_certificate}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened

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
               audit_writer: AuditWriterStub,
               audit_actor: audit_actor(),
               required_gateway_node: self(),
               ssh_certificate: issued_certificate
             )

    refute_receive {:send_console_frame, _agent_id, _frame, _opts}
    assert_receive {:audit, failed_audit}
    assert failed_audit[:action] == :remote_access_session_failed
    assert failed_audit[:details].failure_reason == "ssh_certificate_agent_mismatch"
  end

  defp audit_actor, do: %{id: "user-1", test_pid: self()}

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
