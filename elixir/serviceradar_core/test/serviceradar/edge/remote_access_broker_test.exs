defmodule ServiceRadar.Edge.RemoteAccessBrokerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.RemoteAccessBroker
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Edge.RemoteAccessSSHSessionCredentials

  @moduletag :requires_app

  @permission RemoteAccessSSHCertificatePolicy.permission()
  @principal "srp_v1_6d8b1e49fbe24ad487ce2c5c"

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

  defmodule RecordingStub do
    @moduledoc false

    def ensure_for_session(session, opts) do
      send(opts[:audit_actor].test_pid, {:recording_create, session, opts})
      {:ok, %{id: "recording-1", session_id: Map.get(session, :id) || Map.get(session, "id")}}
    end

    def activate(recording, opts) do
      send(opts[:audit_actor].test_pid, {:recording_active, recording, opts})
      {:ok, Map.put(recording, :status, :active)}
    end

    def complete(recording, stats, opts) do
      send(opts[:audit_actor].test_pid, {:recording_complete, recording, stats, opts})
      {:ok, Map.merge(recording, stats)}
    end

    def fail(recording, reason, stats, opts) do
      send(opts[:audit_actor].test_pid, {:recording_failed, recording, reason, stats, opts})
      {:ok, Map.merge(recording, stats)}
    end
  end

  defmodule FileTransfersStub do
    @moduledoc false

    def handle_agent_frame(frame, opts) do
      send(opts[:audit_actor].test_pid, {:file_transfer_agent_frame, frame, opts})
      {:ok, %{id: "transfer-1"}}
    end
  end

  defmodule LifecycleStub do
    @moduledoc false

    def mark_opening(session_id, _opts) do
      send(lifecycle_owner(), {:lifecycle, :mark_opening, session_id})
      :ok
    end

    def activate_session(session_id, _opts) do
      send(lifecycle_owner(), {:lifecycle, :activate_session, session_id})

      :ok
    end

    def request_close(session_id, opts) do
      send(lifecycle_owner(), {:lifecycle, :request_close, session_id, opts})

      :ok
    end

    def close_session(session_id, opts) do
      send(lifecycle_owner(), {:lifecycle, :close_session, session_id, opts})

      :ok
    end

    def fail_session(session_id, reason, opts \\ []) do
      send(lifecycle_owner(), {:lifecycle, :fail_session, session_id, reason, opts})

      :ok
    end

    defp lifecycle_owner, do: Process.whereis(:remote_access_broker_test_lifecycle_owner)
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
          metadata: session_ssh_grant(),
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
             "ssh_host_key_policy" => "known_hosts",
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

  test "carries the reviewed host key in the agent open frame" do
    approval = %{
      "target" => "host01.example.com:22",
      "fingerprint" => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    }

    session = %{
      session_fixture()
      | metadata: %{
          "target" => %{"host" => "host01.example.com", "port" => 22},
          "ssh_host_key_approval" => approval
        }
    }

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        audit_writer: AuditWriterStub,
        audit_actor: audit_actor(),
        required_gateway_node: self()}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    payload = Jason.decode!(frame.data)
    assert payload["ssh_host_key_policy"] == "known_hosts"
    assert payload["ssh_host_key_approval"] == approval
  end

  test "allows explicit skip-verify host key policy" do
    session = put_in(session_fixture(), [:metadata, "ssh_host_key_policy"], "skip_verify")

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        audit_writer: AuditWriterStub,
        audit_actor: audit_actor(),
        required_gateway_node: self()}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert %{"ssh_host_key_policy" => "skip_verify"} = Jason.decode!(frame.data)
  end

  test "central custody open frames carry only scoped credential broker grants" do
    session =
      session_fixture()
      |> Map.put(:credential_custody_mode, :centrally_brokered)
      |> Map.put(:credential_rule_id, "rule-1")

    broker_grant = %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_type" => "ssh_session",
      "session_id" => "session-1",
      "agent_id" => "agent-1",
      "protocol" => "ssh",
      "credential_rule_id" => "rule-1",
      "credential_secret_ref" => "credentialref:network-credential-secret:test-secret",
      "target" => %{"host" => "10.0.0.10", "port" => 22},
      "allow" => %{"protocols" => ["ssh"], "hosts" => ["10.0.0.10"], "ports" => [22]},
      "ttl_seconds" => 60
    }

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        audit_writer: AuditWriterStub,
        audit_actor: audit_actor(),
        required_gateway_node: self(),
        metadata: %{
          "credential_broker" => broker_grant,
          "ssh" => %{"password" => "must-not-be-carried"}
        }}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    payload = Jason.decode!(frame.data)

    assert payload["credential_mode"] == "centrally_brokered"
    assert payload["credential_broker"] == broker_grant
    refute Map.has_key?(payload, "ssh")
    refute inspect(payload["credential_broker"]) =~ "must-not-be-carried"

    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened
    refute inspect(open_audit) =~ "credentialref:network-credential-secret:test-secret"
    refute inspect(open_audit) =~ "must-not-be-carried"
  end

  test "rejects unsupported host key policy before dispatching open frame" do
    session = put_in(session_fixture(), [:metadata, "ssh_host_key_policy"], "accept_anything")
    previous_flag = Process.flag(:trap_exit, true)

    try do
      assert {:error, :unsupported_ssh_host_key_policy} =
               RemoteAccessBroker.start_link(session, self(),
                 command_bus: CommandBusStub,
                 pubsub: PubSubStub,
                 audit_writer: AuditWriterStub,
                 audit_actor: audit_actor(),
                 required_gateway_node: self()
               )

      assert_receive {:audit, audit}
      assert audit[:action] == :remote_access_session_failed
      assert audit[:details].failure_reason == "unsupported_ssh_host_key_policy"
      refute_receive {:send_console_frame, "agent-1", %{frame_type: "open"}, _opts}, 50
    after
      Process.flag(:trap_exit, previous_flag)
    end
  end

  test "advances durable generic session lifecycle when backed by RemoteAccessSession" do
    Process.register(self(), :remote_access_broker_test_lifecycle_owner)

    on_exit(fn ->
      if Process.whereis(:remote_access_broker_test_lifecycle_owner) == self() do
        Process.unregister(:remote_access_broker_test_lifecycle_owner)
      end
    end)

    session = %RemoteAccessSession{
      id: "session-struct-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      device_uid: "device-1",
      target_host: "10.0.0.20",
      target_port: 2022,
      protocol: :ssh,
      adapter: :ssh,
      credential_custody_mode: :ssh_certificate,
      metadata: %{}
    }

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          audit_writer: AuditWriterStub,
          audit_actor: audit_actor(),
          lifecycle: LifecycleStub,
          required_gateway_node: self()}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:lifecycle, :mark_opening, "session-struct-1"}

    assert %{"target" => %{"device_uid" => "device-1", "host" => "10.0.0.20", "port" => 2022}} =
             Jason.decode!(frame.data)

    auth = frame_auth_from_open(frame)

    auth =
      send_signed_frame(pid, auth, %{
        session_id: "session-struct-1",
        agent_id: "agent-1",
        frame_type: "ready"
      })

    assert_receive {:remote_access_ready, "session-struct-1"}
    assert_receive {:lifecycle, :activate_session, "session-struct-1"}

    send_signed_frame(pid, auth, %{
      session_id: "session-struct-1",
      agent_id: "agent-1",
      frame_type: "close",
      reason: "done"
    })

    assert_receive {:remote_access_closed, "done"}
    assert_receive {:lifecycle, :close_session, "session-struct-1", close_opts}
    assert close_opts[:reason] == "done"
    assert close_opts[:outcome] == :completed
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

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened
    auth = frame_auth_from_open(frame)

    auth =
      send_signed_frame(pid, auth, %{
        session_id: "session-1",
        agent_id: "agent-1",
        frame_type: "data",
        data: "hello"
      })

    assert_receive {:remote_access_data, "hello"}

    send_signed_frame(pid, auth, %{
      session_id: "session-1",
      agent_id: "agent-1",
      frame_type: "close",
      reason: "done"
    })

    assert_receive {:remote_access_closed, "done"}
    assert_receive {:audit, closed_audit}
    assert closed_audit[:action] == :remote_access_session_closed
    assert closed_audit[:details].close_reason == "done"
  end

  test "forwards file-transfer frames to the owner without treating them as terminal output" do
    session = session_fixture()

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          audit_writer: AuditWriterStub,
          audit_actor: audit_actor(),
          file_transfers: FileTransfersStub,
          required_gateway_node: self()}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = open_frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened

    frame = %{
      session_id: "session-1",
      agent_id: "agent-1",
      frame_type: "file_transfer_outcome",
      data: Jason.encode!(%{transfer_id: "transfer-1", status: "completed", entries: []})
    }

    {signed_frame, _auth} = sign_frame(frame_auth_from_open(open_frame), frame)
    send(pid, {:remote_access_frame, signed_frame})

    assert_receive {:remote_access_file_transfer_frame, ^signed_frame}
    assert_receive {:file_transfer_agent_frame, ^signed_frame, frame_opts}
    assert frame_opts[:audit_writer] == AuditWriterStub
    refute_receive {:remote_access_data, _payload}
  end

  test "sends browser file-transfer data frames over the selected agent route" do
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

    payload = %{
      transfer_id: "transfer-1",
      sequence: 1,
      offset: 0,
      data: Base.encode64("hello"),
      eof: false
    }

    assert :ok = RemoteAccessBroker.send_file_transfer_data(pid, payload)

    assert_receive {:send_console_frame, "agent-1",
                    %{frame_type: "file_transfer_data", data: data}, opts}

    assert opts[:required_gateway_node] == self()
    assert Jason.decode!(data)["transfer_id"] == "transfer-1"
    assert Jason.decode!(data)["data"] == Base.encode64("hello")
  end

  test "sends browser desktop control frames over the selected agent route without auditing input tokens" do
    session =
      session_fixture()
      |> Map.put(:protocol, :rdp)
      |> put_in([:metadata, "protocol"], "rdp")

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

    frame = %{
      "session_id" => "session-1",
      "protocol" => "rdp",
      "frame_type" => "desktop.input",
      "input" => %{"kind" => "key", "key" => "Enter", "down" => true}
    }

    assert :ok = RemoteAccessBroker.send_desktop_control(pid, frame)

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "desktop.input", data: data},
                    opts}

    assert opts[:required_gateway_node] == self()
    assert Jason.decode!(data) == frame

    assert_receive {:audit, control_audit}
    assert control_audit[:action] == :remote_access_desktop_control
    assert control_audit[:details].frame_type == "desktop.input"
    assert control_audit[:details].input_kind == "key"
    refute inspect(control_audit) =~ "Enter"
  end

  test "sends rdp open frames with desktop target policy snapshot" do
    session =
      session_fixture()
      |> Map.merge(%{
        protocol: :rdp,
        target_host: "win-01.example.com",
        target_port: 3389,
        device_uid: "device-1",
        credential_custody_mode: :user_present,
        recording_policy: %{"mode" => "metadata_only"}
      })
      |> put_in([:metadata, "protocol"], "rdp")
      |> put_in([:metadata, "desktop_target_id"], "desktop-target-1")
      |> put_in([:metadata, "target_display_name"], "Windows 01")
      |> put_in([:metadata, "target_tls"], %{
        "mode" => "verify_ca",
        "ca_bundle_id" => "corp-rdp-ca",
        "ca_bundle_pem" => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----",
        "server_name" => "win-01.example.com"
      })
      |> put_in([:metadata, "nla"], %{"required" => true})
      |> put_in([:metadata, "screen_policy"], %{
        "max_width" => 1600,
        "max_height" => 900,
        "frame_rate" => 30,
        "bitrate_kbps" => 6000
      })
      |> put_in([:metadata, "redirection_policy"], %{"clipboard" => "local_to_remote"})
      |> put_in([:metadata, "rdp.kdc_proxy_url"], "tcp://kdc.example.com:88")
      |> put_in([:metadata, "rdp.kerberos_hostname"], "win-01.example.com")
      |> put_in([:metadata, "desktop_allowed_principals"], ["alice@example.com"])

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        audit_writer: AuditWriterStub,
        audit_actor: audit_actor(),
        required_gateway_node: self()}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open", data: data}, _opts}

    decoded = Jason.decode!(data)
    assert decoded["schema"] == "serviceradar.desktop.open.v1"
    assert decoded["protocol"] == "rdp"
    assert decoded["session_id"] == "session-1"
    assert decoded["actor_id"] == "user-1"
    assert decoded["agent_id"] == "agent-1"
    assert decoded["gateway_id"] == "gateway-1"
    assert decoded["metadata"]["media_session_id"] == "desktop-media-session-1"
    assert decoded["metadata"]["route_id"] == "agent-1"
    assert decoded["metadata"]["target_id"] == "desktop-target-1"
    assert decoded["metadata"]["encoding_hint"] == "srdp"
    assert is_binary(decoded["metadata"]["lease_token"])
    assert byte_size(decoded["metadata"]["lease_token"]) == 32

    target = decoded["target"]
    assert target["target_id"] == "desktop-target-1"
    assert target["display_name"] == "Windows 01"
    assert target["device_uid"] == "device-1"
    assert target["protocol"] == "rdp"
    assert target["route"]["selected_agent_id"] == "agent-1"
    assert target["route"]["selected_gateway_id"] == "gateway-1"
    assert target["upstream"] == %{"host" => "win-01.example.com", "port" => 3389}

    assert target["tls"] == %{
             "mode" => "verify",
             "ca_bundle_id" => "corp-rdp-ca",
             "ca_bundle_pem" => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----",
             "nla_mode" => "required",
             "server_name" => "win-01.example.com"
           }

    assert target["credential"] == %{
             "mode" => "memory_user",
             "allowed_principals" => ["alice@example.com"]
           }

    assert target["screen"]["bitrate_bps"] == 6_000_000
    assert target["redirection"]["clipboard_mode"] == "text_to_remote"
    assert target["recording"] == %{"metadata_enabled" => true}
    assert target["metadata"]["rdp.kdc_proxy_url"] == "tcp://kdc.example.com:88"
    assert target["metadata"]["rdp.kerberos_hostname"] == "win-01.example.com"
    refute Map.has_key?(target["metadata"], "target_tls")
    refute Map.has_key?(target["metadata"], "desktop_allowed_principals")
  end

  test "recording hook receives only policy-gated counters and lifecycle state" do
    session =
      Map.put(session_fixture(), :recording_policy, %{
        "enabled" => true,
        "retention_days" => 7,
        "private_key" => "must-not-be-used"
      })

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          audit_writer: AuditWriterStub,
          audit_actor: audit_actor(),
          recordings: RecordingStub,
          required_gateway_node: self()}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened
    assert_receive {:recording_create, ^session, recording_opts}
    refute inspect(recording_opts) =~ "must-not-be-used"
    auth = frame_auth_from_open(frame)

    auth =
      send_signed_frame(pid, auth, %{
        session_id: "session-1",
        agent_id: "agent-1",
        frame_type: "ready"
      })

    assert_receive {:remote_access_ready, "session-1"}
    assert_receive {:recording_active, %{id: "recording-1"}, _opts}

    assert :ok = RemoteAccessBroker.send_input(pid, "whoami\r")

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "data", data: "whoami\r"},
                    _opts}

    assert_receive {:audit, input_audit}
    assert input_audit[:details].input_bytes == 7

    auth =
      send_signed_frame(pid, auth, %{
        session_id: "session-1",
        agent_id: "agent-1",
        frame_type: "data",
        data: "root\n"
      })

    assert_receive {:remote_access_data, "root\n"}

    send_signed_frame(pid, auth, %{
      session_id: "session-1",
      agent_id: "agent-1",
      frame_type: "close",
      reason: "done"
    })

    assert_receive {:remote_access_closed, "done"}
    assert_receive {:recording_complete, %{id: "recording-1"}, stats, _opts}
    refute_receive {:recording_complete, %{id: "recording-1"}, _stats, _opts}, 100

    assert stats == %{input_bytes: 7, output_bytes: 5, event_count: 2}
    refute inspect(stats) =~ "whoami"
    refute inspect(stats) =~ "root"
    refute inspect(stats) =~ "must-not-be-used"
  end

  test "open frame carries sanitized recording policies for agent-side gates" do
    session =
      session_fixture()
      |> Map.put(:recording_policy, %{"enabled" => true, "retention_days" => 7})
      |> Map.put(:enhanced_recording_policy, %{
        "enabled" => true,
        "required" => true,
        "mode" => "bpf",
        "private_key" => "must-not-leak"
      })

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        audit_writer: AuditWriterStub,
        audit_actor: audit_actor(),
        required_gateway_node: self()}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    payload = Jason.decode!(frame.data)

    assert payload["recording_policy"] == %{"enabled" => true, "retention_days" => 7}

    assert payload["enhanced_recording_policy"] == %{
             "enabled" => true,
             "required" => true,
             "mode" => "bpf",
             "private_key" => "REDACTED"
           }

    refute inspect(frame) =~ "must-not-leak"
  end

  test "ignores remote-access frames not owned by the session and agent" do
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

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened
    auth = frame_auth_from_open(frame)

    send(
      pid,
      {:remote_access_frame,
       %{session_id: "session-1", agent_id: "agent-2", frame_type: "data", data: "wrong-agent"}}
    )

    send(pid, {:remote_access_frame, %{frame_type: "data", data: "missing-agent-id"}})

    send(
      pid,
      {:remote_access_frame,
       %{session_id: "session-1", agent_id: "agent-2", frame_type: "close", reason: "wrong-agent"}}
    )

    send(
      pid,
      {:remote_access_frame,
       %{session_id: "session-2", agent_id: "agent-1", frame_type: "data", data: "wrong-session"}}
    )

    send(
      pid,
      {:remote_access_frame,
       %{
         session_id: "session-2",
         agent_id: "agent-1",
         frame_type: "close",
         reason: "wrong-session"
       }}
    )

    refute_receive {:remote_access_data, _data}, 50
    refute_receive {:remote_access_closed, _reason}, 50

    auth =
      send_signed_frame(pid, auth, %{
        session_id: "session-1",
        agent_id: "agent-1",
        frame_type: "data",
        data: "owned"
      })

    assert_receive {:remote_access_data, "owned"}

    send_signed_frame(pid, auth, %{
      session_id: "session-1",
      agent_id: "agent-1",
      frame_type: "close",
      reason: "done"
    })

    assert_receive {:remote_access_closed, "done"}
  end

  test "rejects owned remote-access frames with unknown frame types" do
    session = session_fixture()
    telemetry_handler_id = "remote-access-frame-rejected-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_handler_id,
        [:serviceradar, :remote_access, :broker, :frame_rejected],
        fn event, measurements, metadata, owner ->
          send(owner, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler_id) end)

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

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened
    auth = frame_auth_from_open(frame)

    send_signed_frame(pid, auth, %{
      session_id: "session-1",
      agent_id: "agent-1",
      frame_type: "desktop.secret"
    })

    assert_receive {:audit, reject_audit}
    assert reject_audit[:action] == :remote_access_session_frame_rejected
    assert reject_audit[:severity] == :high
    assert reject_audit[:details].frame_type == "desktop.secret"
    assert reject_audit[:details].failure_reason == "unknown_frame_type"

    assert_receive {:telemetry, [:serviceradar, :remote_access, :broker, :frame_rejected],
                    %{count: 1}, telemetry_metadata}

    assert telemetry_metadata.frame_type == "desktop.secret"
    assert telemetry_metadata.reason == "unknown_frame_type"
    refute_receive {:remote_access_data, _data}, 50
  end

  test "opens from a user-present credential grant without persisted session SSH metadata" do
    session = %{
      id: "session-1",
      requested_by: "user-1",
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
                 username: "mfreeman",
                 public_key: "ssh-ed25519 AAAATEST user@workstation",
                 private_key:
                   "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
                 passphrase: "session-passphrase",
                 target: %{device_uid: "device-1", host: "10.0.0.11", port: 2222},
                 accounts: [%{name: "mfreeman", principals: [@principal]}]
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
               "username" => "mfreeman",
               "private_key" =>
                 "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
               "passphrase" => "session-passphrase",
               "certificate" => "ssh-ed25519-cert-v01@openssh.com AAAATEST"
             }
           } = Jason.decode!(frame.data)

    refute inspect(grant.ssh_certificate) =~ "OPENSSH PRIVATE KEY"
    refute inspect(grant.audit) =~ "session-passphrase"
  end

  test "merges issued SSH certificate envelopes with in-memory user-present session keys" do
    session = session_fixture()

    issued_certificate = %{
      session_id: "session-1",
      agent_id: "agent-1",
      protocol: "ssh",
      credential_mode: "ssh_certificate",
      target: %{"host" => "10.0.0.10", "port" => 22},
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
        metadata: %{
          "ssh" => %{
            "username" => "stale-login",
            "private_key" => "session-private-key",
            "passphrase" => "session-passphrase",
            "certificate" => "stale-certificate"
          }
        },
        ssh_certificate: issued_certificate}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    assert_receive {:audit, open_audit}
    assert open_audit[:action] == :remote_access_session_opened

    assert %{
             "credential_mode" => "ssh_certificate",
             "target" => %{"host" => "10.0.0.10", "port" => 22},
             "ssh" => %{
               "username" => "ubuntu",
               "private_key" => "session-private-key",
               "passphrase" => "session-passphrase",
               "certificate" => "issued-certificate"
             }
           } = Jason.decode!(frame.data)
  end

  test "does not use persisted session metadata as SSH credential material" do
    session =
      put_in(session_fixture(), [:metadata, "ssh"], %{
        "username" => "persisted-login",
        "private_key" => "persisted-private-key",
        "password" => "persisted-password",
        "certificate" => "persisted-certificate"
      })

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        audit_writer: AuditWriterStub,
        audit_actor: audit_actor(),
        required_gateway_node: self()}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}
    payload = Jason.decode!(frame.data)

    refute Map.has_key?(payload, "ssh")
    refute inspect(payload) =~ "persisted-private-key"
    refute inspect(payload) =~ "persisted-password"
    refute inspect(payload) =~ "persisted-certificate"
  end

  test "durable session target wins over caller metadata" do
    session =
      Map.merge(session_fixture(), %{
        device_uid: "device-1",
        target_host: "10.0.0.10",
        target_port: 22,
        metadata: %{
          "target" => %{"host" => "metadata-retarget.example", "port" => 2022},
          "ssh" => %{"username" => "root", "private_key" => "session-key"}
        }
      })

    start_supervised!(
      {RemoteAccessBroker,
       {session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        audit_writer: AuditWriterStub,
        audit_actor: audit_actor(),
        required_gateway_node: self(),
        metadata: %{"target" => %{"host" => "opts-retarget.example", "port" => 2222}}}}
    )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, _opts}

    assert %{
             "target" => %{"device_uid" => "device-1", "host" => "10.0.0.10", "port" => 22}
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

  test "rejects SSH certificate envelopes scoped to another target" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    session =
      Map.merge(session_fixture(), %{
        device_uid: "device-1",
        target_host: "10.0.0.10",
        target_port: 22
      })

    issued_certificate = %{
      session_id: "session-1",
      agent_id: "agent-1",
      protocol: "ssh",
      credential_mode: "ssh_certificate",
      target: %{"device_uid" => "other-device", "host" => "10.0.0.11", "port" => 22},
      ssh: %{"username" => "ubuntu", "certificate" => "issued-certificate"}
    }

    assert {:error, :ssh_certificate_target_mismatch} =
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
    assert failed_audit[:details].failure_reason == "ssh_certificate_target_mismatch"
  end

  defp audit_actor, do: %{id: "user-1", test_pid: self()}

  defp session_fixture do
    %{
      id: "session-1",
      requested_by: "user-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      metadata: %{"target" => %{"host" => "10.0.0.10", "port" => 22}}
    }
  end

  defp session_ssh_grant do
    %{
      "ssh" => %{
        "username" => "root",
        "private_key" => "session-key",
        "certificate" => "session-cert"
      }
    }
  end

  defp frame_auth_from_open(%{data: data}) do
    %{"frame_auth" => %{"key" => key}} = Jason.decode!(data)
    {:ok, decoded_key} = Base.url_decode64(key, padding: false)
    %{key: decoded_key, seq: 0}
  end

  defp send_signed_frame(pid, auth, frame) do
    {frame, auth} = sign_frame(auth, frame)
    send(pid, {:remote_access_frame, frame})
    auth
  end

  defp sign_frame(auth, frame) do
    seq = auth.seq + 1
    payload_hash = :sha256 |> :crypto.hash(frame_data(frame)) |> Base.encode16(case: :lower)

    signature =
      :hmac
      |> :crypto.mac(:sha256, auth.key, canonical_frame_binding(frame, seq, payload_hash))
      |> Base.url_encode64(padding: false)

    {
      Map.merge(frame, %{seq: seq, payload_sha256: payload_hash, signature: signature}),
      %{auth | seq: seq}
    }
  end

  defp canonical_frame_binding(frame, seq, payload_hash) do
    Enum.join(
      [
        "serviceradar.remote_access.frame.v1",
        Map.get(frame, :session_id) || Map.get(frame, "session_id") || "",
        Map.get(frame, :agent_id) || Map.get(frame, "agent_id") || "",
        Integer.to_string(seq),
        Map.get(frame, :frame_type) || Map.get(frame, "frame_type") || "",
        Integer.to_string(Map.get(frame, :cols) || Map.get(frame, "cols") || 0),
        Integer.to_string(Map.get(frame, :rows) || Map.get(frame, "rows") || 0),
        Map.get(frame, :reason) || Map.get(frame, "reason") || "",
        payload_hash
      ],
      "\n"
    )
  end

  defp frame_data(frame), do: Map.get(frame, :data) || Map.get(frame, "data") || ""
end
