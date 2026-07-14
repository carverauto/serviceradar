defmodule ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandlerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandler

  @principal "srp_v1_6d8b1e49fbe24ad487ce2c5c"
  @moduletag :db_free

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    case Process.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _pid -> :ok
    end

    :ok
  end

  defmodule SessionsStub do
    @moduledoc false

    def attach_with_ticket(ticket, opts) do
      send(test_pid(opts), {:attach_with_ticket, ticket, opts})

      {:ok,
       %RemoteAccessSession{
         id: opts[:session_id],
         device_uid: scope_value(opts, :device_uid, "linux-1"),
         target_kind: :inventory_device,
         target_host: scope_value(opts, :target_host, "10.0.0.10"),
         target_port: scope_value(opts, :target_port, 22),
         protocol: scope_value(opts, :protocol, :ssh),
         adapter: scope_value(opts, :adapter, :ssh),
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         credential_rule_id: scope_value(opts, :credential_rule_id, nil),
         credential_custody_mode: opts |> Keyword.fetch!(:scope) |> Map.get(:credential_custody_mode, :ssh_certificate),
         requested_by: scope_value(opts, :session_owner_id, scope_user_id(opts)),
         rbac_decision: :allowed,
         status: :attached,
         attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
         idle_timeout_seconds: 30,
         absolute_timeout_seconds: 120,
         metadata: Map.put(scope_value(opts, :session_metadata, %{}), "test_pid", test_pid(opts)),
         inserted_at: DateTime.utc_now(),
         updated_at: DateTime.utc_now()
       }}
    end

    def request_close(session_id, opts) do
      send(test_pid(opts), {:request_close, session_id, opts})
      {:ok, %RemoteAccessSession{id: session_id, status: :closing}}
    end

    def close_session(session_id, opts) do
      send(test_pid(opts), {:close_session, session_id, opts})
      {:ok, %RemoteAccessSession{id: session_id, status: :closed}}
    end

    def expire_session(session_id, opts) do
      send(test_pid(opts), {:expire_session, session_id, opts})
      {:ok, %RemoteAccessSession{id: session_id, status: :expired}}
    end

    def fail_session(session_id, reason, opts) do
      send(test_pid(opts), {:fail_session, session_id, reason, opts})
      {:ok, %RemoteAccessSession{id: session_id, status: :failed}}
    end

    def record_activity(session_id, opts) do
      send(test_pid(opts), {:record_activity, session_id, opts})
      {:ok, %RemoteAccessSession{id: session_id, status: :active}}
    end

    defp test_pid(opts), do: opts |> Keyword.fetch!(:scope) |> Map.fetch!(:test_pid)

    defp scope_value(opts, key, default) do
      opts
      |> Keyword.fetch!(:scope)
      |> Map.get(key, default)
    end

    defp scope_user_id(opts) do
      opts
      |> Keyword.fetch!(:scope)
      |> get_in([:user, :id])
    end
  end

  defmodule BrokerStub do
    @moduledoc false

    def start_link(session, owner, opts) do
      pid =
        spawn_link(fn ->
          loop(%{session: session, owner: owner, opts: opts})
        end)

      send(session.metadata["test_pid"], {:broker_started, session.id, opts})
      {:ok, pid}
    end

    def send_input(pid, data) do
      send(pid, {:send_input, self(), data})
      :ok
    end

    def send_application_request(pid, payload) do
      send(pid, {:send_application_request, self(), payload})
      :ok
    end

    def send_application_data(pid, payload) do
      send(pid, {:send_application_data, self(), payload})
      :ok
    end

    def send_tcp_data(pid, payload) do
      send(pid, {:send_tcp_data, self(), payload})
      :ok
    end

    def send_file_transfer_data(pid, payload) do
      send(pid, {:send_file_transfer_data, self(), payload})
      :ok
    end

    def resize(pid, cols, rows) do
      send(pid, {:resize, self(), cols, rows})
      :ok
    end

    def close(pid, reason) do
      send(pid, {:close, self(), reason})
      :ok
    end

    defp loop(state) do
      receive do
        {:send_input, caller, data} ->
          send(state.session.metadata["test_pid"], {:broker_input, caller, data})
          loop(state)

        {:send_application_request, caller, payload} ->
          send(state.session.metadata["test_pid"], {:broker_application_request, caller, payload})
          loop(state)

        {:send_application_data, caller, payload} ->
          send(state.session.metadata["test_pid"], {:broker_application_data, caller, payload})
          loop(state)

        {:send_tcp_data, caller, payload} ->
          send(state.session.metadata["test_pid"], {:broker_tcp_data, caller, payload})
          loop(state)

        {:send_file_transfer_data, caller, payload} ->
          send(state.session.metadata["test_pid"], {:broker_file_transfer_data, caller, payload})
          loop(state)

        {:resize, caller, cols, rows} ->
          send(state.session.metadata["test_pid"], {:broker_resize, caller, cols, rows})
          loop(state)

        {:close, caller, reason} ->
          send(state.session.metadata["test_pid"], {:broker_close, caller, reason})
          :ok
      end
    end
  end

  defmodule CentralCredentialGrantResolverStub do
    @moduledoc false

    def build_broker_grant(session, opts) do
      send(opts[:scope].test_pid, {:central_credential_grant_requested, session.id, opts})

      {:ok,
       %{
         broker_opts: [
           metadata: %{
             "credential_broker" => %{
               "schema" => "serviceradar.edge_credential_broker_grant.v1",
               "grant_type" => "ssh_session",
               "session_id" => session.id,
               "agent_id" => session.agent_id,
               "protocol" => "ssh",
               "credential_rule_id" => session.credential_rule_id,
               "credential_secret_ref" => "credentialref:network-credential-secret:test-secret",
               "target" => %{
                 "device_uid" => session.device_uid,
                 "host" => session.target_host,
                 "port" => session.target_port
               },
               "allow" => %{
                 "protocols" => ["ssh"],
                 "hosts" => [session.target_host],
                 "ports" => [session.target_port]
               },
               "ttl_seconds" => 60
             }
           },
           credential_mode: "centrally_brokered"
         ],
         audit: %{
           credential_custody_mode: "centrally_brokered",
           credential_rule_id: session.credential_rule_id
         }
       }}
    end
  end

  defmodule AuthorizationStub do
    @moduledoc false

    def authorize_current(%{user: %{id: id}} = scope, required_permissions) do
      current_permissions = permissions(id)

      if Enum.all?(required_permissions, &MapSet.member?(current_permissions, &1)) do
        {:ok, Map.put(scope, :permissions, current_permissions)}
      else
        {:error, :permission_revoked}
      end
    end

    def authorize_current(_scope, _required_permissions), do: {:error, :permission_revoked}

    def set_permissions(user_id, permissions) do
      Process.put({__MODULE__, user_id}, MapSet.new(permissions))
    end

    defp permissions(user_id), do: Process.get({__MODULE__, user_id}, MapSet.new())
  end

  defmodule SignerStub do
    @moduledoc false
    @behaviour RemoteAccessSSHCertificates

    @impl true
    def sign_user_certificate(request, _opts) do
      send(Process.whereis(__MODULE__), {:sign_user_certificate, request})

      {:ok,
       %{
         certificate: "ssh-ed25519-cert-v01@openssh.com AAAATEST",
         expires_at: DateTime.add(DateTime.utc_now(), 900, :second),
         fingerprint: "SHA256:test-cert",
         serial: 42,
         ca_key_id: "test-ca"
       }}
    end
  end

  defmodule DesktopWebRTCStub do
    @moduledoc false

    def close_all_for_session(session_id, opts) do
      opts
      |> Keyword.fetch!(:scope)
      |> Map.fetch!(:test_pid)
      |> send({:desktop_webrtc_close_all, session_id, opts})

      {:ok, %{closed_viewer_count: 1}}
    end
  end

  test "attach consumes ticket, starts broker, and does not echo ticket" do
    {:ok, state} = init_state("session-1")

    assert {:push, {:text, response}, attached} =
             RemoteAccessStreamHandler.handle_in({attach_payload("session-1"), [opcode: :text]}, state)

    assert %{"type" => "ready", "session_id" => "session-1"} = Jason.decode!(response)
    refute response =~ "srra_test_ticket"
    assert attached.attached?
    assert is_reference(attached.idle_timer)
    assert is_reference(attached.absolute_timer)
    assert_receive {:attach_with_ticket, "srra_test_ticket", _opts}
    assert_receive {:broker_started, "session-1", opts}
    assert opts[:cols] == 132
    assert opts[:rows] == 43

    RemoteAccessStreamHandler.terminate(:normal, attached)
  end

  test "attach rejects a session owned by another user before broker start" do
    {:ok, state} = init_state("session-cross-owner", session_owner_id: "user-2")

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             RemoteAccessStreamHandler.handle_in(
               {attach_payload("session-cross-owner"), [opcode: :text]},
               state
             )

    assert %{"type" => "error", "message" => "Invalid or expired remote access ticket."} =
             Jason.decode!(response)

    refute_receive {:broker_started, "session-cross-owner", _opts}
  end

  test "unknown browser messages are logged and emitted as telemetry" do
    {:ok, state} = init_state("session-unknown-message")

    assert {:push, {:text, _response}, attached} =
             RemoteAccessStreamHandler.handle_in({attach_payload("session-unknown-message"), [opcode: :text]}, state)

    event = [:serviceradar, :remote_access, :stream, :unknown_message]
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, test_pid ->
          send(test_pid, {:unknown_stream_message, measurements, metadata})
        end,
        self()
      )

    log =
      try do
        capture_log(fn ->
          assert {:ok, ^attached} =
                   RemoteAccessStreamHandler.handle_in(
                     {Jason.encode!(%{type: "probe", payload: "ignored"}), [opcode: :text]},
                     attached
                   )
        end)
      after
        :telemetry.detach(handler_id)
      end

    assert log =~ "Ignored unknown remote access stream message"

    assert_receive {:unknown_stream_message, %{count: 1},
                    %{
                      actor_id: "user-1",
                      message_type: "probe",
                      session_id: "session-unknown-message",
                      source: :browser_text,
                      topic: "remote_access:session-unknown-message"
                    }}

    refute_receive {:broker_input, _caller, _data}

    RemoteAccessStreamHandler.terminate(:normal, attached)
  end

  test "unexpected server messages are observable without logging payload bytes" do
    {:ok, state} = init_state("session-unknown-info")

    event = [:serviceradar, :remote_access, :stream, :unknown_message]
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, test_pid ->
          send(test_pid, {:unknown_stream_message, measurements, metadata})
        end,
        self()
      )

    log =
      try do
        capture_log(fn ->
          assert {:ok, ^state} =
                   RemoteAccessStreamHandler.handle_info(
                     {:unexpected_probe, "secret-payload"},
                     state
                   )
        end)
      after
        :telemetry.detach(handler_id)
      end

    assert log =~ "Ignored unknown remote access stream message"
    refute log =~ "secret-payload"

    assert_receive {:unknown_stream_message, %{count: 1},
                    %{
                      actor_id: "user-1",
                      message_type: "unexpected_probe",
                      session_id: "session-unknown-info",
                      source: :server_info,
                      topic: "remote_access:session-unknown-info"
                    }}
  end

  test "user-present attach passes SSH credential to broker without echoing it" do
    {:ok, state} = init_state("session-user-present", credential_custody_mode: :user_present)

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-user-present",
        cols: 132,
        rows: 43,
        credential: %{
          username: "alice",
          private_key: "session-private-key",
          passphrase: "session-passphrase"
        }
      })

    assert {:push, {:text, response}, attached} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "ready", "session_id" => "session-user-present"} = Jason.decode!(response)
    refute response =~ "srra_test_ticket"
    refute response =~ "session-private-key"
    refute response =~ "session-passphrase"

    assert_receive {:broker_started, "session-user-present", opts}
    assert opts[:credential_mode] == "user_present"
    assert opts[:metadata]["ssh"]["username"] == "alice"
    assert opts[:metadata]["ssh"]["private_key"] == "session-private-key"
    assert opts[:metadata]["ssh"]["passphrase"] == "session-passphrase"

    RemoteAccessStreamHandler.terminate(:normal, attached)
  end

  test "user-present RDP attach passes a desktop credential grant to broker without echoing it" do
    {:ok, state} =
      init_state("session-rdp-user-present",
        protocol: :rdp,
        adapter: :rdp,
        device_uid: "windows-1",
        target_host: "win-1.example.com",
        target_port: 3389,
        credential_custody_mode: :user_present,
        session_metadata: %{"desktop_target_id" => "desktop-target-1"}
      )

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-rdp-user-present",
        credential: %{
          username: "EXAMPLE\\alice",
          password: "rdp-session-password"
        }
      })

    assert {:push, {:text, response}, attached} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "ready", "session_id" => "session-rdp-user-present"} = Jason.decode!(response)
    refute response =~ "srra_test_ticket"
    refute response =~ "rdp-session-password"

    assert_receive {:broker_started, "session-rdp-user-present", opts}
    assert opts[:credential_mode] == "user_present"

    assert opts[:metadata]["credential_grant"] == %{
             "mode" => "memory_user",
             "username" => "EXAMPLE\\alice",
             "password" => "rdp-session-password",
             "actor_id" => "user-1",
             "session_id" => "session-rdp-user-present",
             "target_id" => "desktop-target-1",
             "route_id" => "agent-1"
           }

    refute Map.has_key?(opts[:metadata], "ssh")

    RemoteAccessStreamHandler.terminate(:normal, attached)
  end

  test "user-present RDP attach rejects SSH-style private key credentials" do
    {:ok, state} =
      init_state("session-rdp-private-key",
        protocol: :rdp,
        adapter: :rdp,
        credential_custody_mode: :user_present,
        session_metadata: %{"desktop_target_id" => "desktop-target-1"}
      )

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-rdp-private-key",
        credential: %{
          username: "alice",
          password: "rdp-session-password",
          private_key: "session-private-key"
        }
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "The supplied SSH credential was rejected by policy."} =
             Jason.decode!(response)

    assert_receive {:fail_session, "session-rdp-private-key", :credential_policy_denied, _opts}
    refute_receive {:broker_started, "session-rdp-private-key", _opts}
  end

  test "ssh certificate attach issues cert from server-side identity claims" do
    Process.register(self(), SignerStub)

    original_config =
      Application.get_env(:serviceradar_core, RemoteAccessSSHCertificates, [])

    Application.put_env(:serviceradar_core, RemoteAccessSSHCertificates, signer: SignerStub)

    on_exit(fn ->
      Application.put_env(
        :serviceradar_core,
        RemoteAccessSSHCertificates,
        original_config
      )

      if Process.whereis(SignerStub) == self(), do: Process.unregister(SignerStub)
    end)

    {:ok, state} =
      init_state("session-cert",
        credential_custody_mode: :ssh_certificate,
        identity_claims: %{
          "groups" => ["linux-admins"],
          "service_radar_auth_method" => "oidc"
        },
        session_metadata: %{
          "ssh_accounts" => [
            %{"name" => "mfreeman", "principals" => [@principal]}
          ],
          "ssh_principal_mappings" => [
            %{
              "source" => "groups",
              "value" => "linux-admins",
              "principals" => [@principal]
            }
          ],
          "ssh_certificate_ttl_seconds" => 900
        }
      )

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-cert",
        cols: 132,
        rows: 43,
        credential: %{
          username: "mfreeman",
          public_key: "ssh-ed25519 AAAATEST user@workstation",
          private_key: "session-private-key",
          passphrase: "session-passphrase"
        }
      })

    assert {:push, {:text, response}, attached} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "ready", "session_id" => "session-cert"} = Jason.decode!(response)
    refute response =~ "session-private-key"
    refute response =~ "session-passphrase"
    refute response =~ "AAAATEST"

    assert_receive {:sign_user_certificate, sign_request}
    assert sign_request.principals == [@principal]
    assert sign_request.ttl_seconds == 900

    assert_receive {:broker_started, "session-cert", opts}
    assert opts[:ssh_certificate].credential_mode == "ssh_certificate"
    assert opts[:ssh_certificate].ssh["username"] == "mfreeman"
    assert opts[:ssh_certificate].ssh["certificate"] =~ "ssh-ed25519-cert-v01@openssh.com"
    assert opts[:metadata]["ssh"]["private_key"] == "session-private-key"
    assert opts[:metadata]["ssh"]["passphrase"] == "session-passphrase"

    refute inspect(sign_request) =~ "browser-admins"
    refute inspect(sign_request) =~ "session-private-key"

    RemoteAccessStreamHandler.terminate(:normal, attached)
  end

  test "ssh certificate attach rejects every browser-supplied identity and principal policy field" do
    controlled_fields = [
      {"accounts", [%{"name" => "mfreeman", "principals" => [@principal]}]},
      {"allowed_principals", [@principal]},
      {"claims", %{"groups" => ["browser-admins"]}},
      {"principal_mappings",
       [
         %{"source" => "groups", "value" => "browser-admins", "principals" => [@principal]}
       ]},
      {"principals", [@principal]},
      {"requested_principals", [@principal]},
      {"ssh_accounts", [%{"name" => "mfreeman", "principals" => [@principal]}]}
    ]

    for {{field, value}, index} <- Enum.with_index(controlled_fields) do
      session_id = "session-cert-policy-fields-#{index}"

      {:ok, state} =
        init_state(session_id,
          credential_custody_mode: :ssh_certificate,
          identity_claims: %{"groups" => ["linux-admins"]}
        )

      credential =
        Map.put(
          %{
            "username" => "mfreeman",
            "public_key" => "ssh-ed25519 AAAATEST user@workstation",
            "private_key" => "session-private-key"
          },
          field,
          value
        )

      payload =
        Jason.encode!(%{
          type: "attach",
          ticket: "srra_test_ticket",
          session_id: session_id,
          credential: credential
        })

      assert {:stop, :normal, 1008, [{:text, response}], ^state} =
               RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

      assert %{
               "type" => "error",
               "message" => "The supplied SSH credential was rejected by policy."
             } = Jason.decode!(response)

      assert_receive {:fail_session, ^session_id, :credential_policy_denied, _opts}
      refute response =~ "browser-admins"
    end
  end

  test "ssh certificate attach requires a session key" do
    {:ok, state} =
      init_state("session-cert-missing-key", credential_custody_mode: :ssh_certificate)

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-cert-missing-key"
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "A per-session SSH credential is required."} =
             Jason.decode!(response)
  end

  test "user-present attach rejects oversized credential fields" do
    {:ok, state} = init_state("session-user-present-large-key", credential_custody_mode: :user_present)

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-user-present-large-key",
        credential: %{
          username: "alice",
          private_key: String.duplicate("k", 65_537)
        }
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "The supplied SSH credential was rejected by policy."} =
             Jason.decode!(response)

    assert_receive {:fail_session, "session-user-present-large-key", :credential_policy_denied, _opts}
    refute_receive {:broker_started, "session-user-present-large-key", _opts}
  end

  test "centrally brokered custody resolves a scoped broker grant before attach" do
    {:ok, state} =
      init_state("session-centrally-brokered",
        credential_custody_mode: :centrally_brokered,
        credential_rule_id: "rule-1"
      )

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-centrally-brokered"
      })

    assert {:push, {:text, response}, attached} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "ready", "session_id" => "session-centrally-brokered"} = Jason.decode!(response)

    assert_receive {:central_credential_grant_requested, "session-centrally-brokered", resolver_opts}
    assert resolver_opts[:scope].test_pid == self()

    assert_receive {:broker_started, "session-centrally-brokered", broker_opts}
    assert broker_opts[:credential_mode] == "centrally_brokered"

    assert broker_opts[:metadata]["credential_broker"] == %{
             "schema" => "serviceradar.edge_credential_broker_grant.v1",
             "grant_type" => "ssh_session",
             "session_id" => "session-centrally-brokered",
             "agent_id" => "agent-1",
             "protocol" => "ssh",
             "credential_rule_id" => "rule-1",
             "credential_secret_ref" => "credentialref:network-credential-secret:test-secret",
             "target" => %{"device_uid" => "linux-1", "host" => "10.0.0.10", "port" => 22},
             "allow" => %{"protocols" => ["ssh"], "hosts" => ["10.0.0.10"], "ports" => [22]},
             "ttl_seconds" => 60
           }

    refute response =~ "credentialref:network-credential-secret:test-secret"

    RemoteAccessStreamHandler.terminate(:normal, attached)
  end

  test "centrally brokered attach rejects browser-supplied plaintext credentials" do
    {:ok, state} =
      init_state("session-centrally-brokered-browser-credential",
        credential_custody_mode: :centrally_brokered,
        credential_rule_id: "rule-1"
      )

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-centrally-brokered-browser-credential",
        credential: %{"username" => "root", "password" => "browser-secret"}
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "The supplied SSH credential was rejected by policy."} =
             Jason.decode!(response)

    assert_receive {:fail_session, "session-centrally-brokered-browser-credential", :credential_policy_denied, _opts}
    refute_receive {:central_credential_grant_requested, _session_id, _opts}
    refute_receive {:broker_started, "session-centrally-brokered-browser-credential", _opts}
  end

  test "attach rejects oversized terminal dimensions before broker start" do
    {:ok, state} = init_state("session-oversized-attach")

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-oversized-attach",
        cols: 10_000,
        rows: 43
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "The supplied SSH credential was rejected by policy."} =
             Jason.decode!(response)

    assert_receive {:fail_session, "session-oversized-attach", :invalid_size, _opts}
    refute_receive {:broker_started, "session-oversized-attach", _opts}
  end

  test "rejected attach does not echo the supplied ticket" do
    {:ok, state} = init_state("session-reject")

    supplied_ticket = "srra_secret_ticket_value"

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: supplied_ticket,
        session_id: "wrong-session"
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "Invalid or expired remote access ticket."} =
             Jason.decode!(response)

    refute response =~ supplied_ticket
  end

  test "data and resize frames forward to broker and refresh idle timer" do
    {:ok, state} = init_state("session-2")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-2"), [opcode: :text]}, state)

    original_timer = attached.idle_timer

    assert {:ok, after_data} =
             RemoteAccessStreamHandler.handle_in(
               {Jason.encode!(%{type: "data", data: Base.encode64("whoami\r")}), [opcode: :text]},
               attached
             )

    assert_receive {:broker_input, _caller, "whoami\r"}
    assert after_data.idle_timer != original_timer

    assert {:ok, after_resize} =
             RemoteAccessStreamHandler.handle_in(
               {Jason.encode!(%{type: "resize", cols: 120, rows: 34}), [opcode: :text]},
               after_data
             )

    assert_receive {:broker_resize, _caller, 120, 34}
    assert after_resize.idle_timer != after_data.idle_timer

    RemoteAccessStreamHandler.terminate(:normal, after_resize)
  end

  test "RDP activity refreshes stream idle state and durably persists at a bounded rate" do
    AuthorizationStub.set_permissions("user-1", ["devices.remote_access.rdp.open"])

    {:ok, state} =
      init_state("session-rdp-activity",
        protocol: :rdp,
        adapter: :rdp,
        target_port: 3389,
        authorization_module: AuthorizationStub
      )

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in(
        {attach_payload("session-rdp-activity"), [opcode: :text]},
        state
      )

    original_timer = attached.idle_timer
    activity = Jason.encode!(%{type: "activity", session_id: "session-rdp-activity"})

    assert {:ok, after_first_activity} =
             RemoteAccessStreamHandler.handle_in({activity, [opcode: :text]}, attached)

    assert_receive {:record_activity, "session-rdp-activity", opts}
    assert opts[:scope].user.id == "user-1"
    assert is_integer(after_first_activity.last_activity_persisted_at_ms)
    assert after_first_activity.idle_timer != original_timer

    assert {:ok, after_second_activity} =
             RemoteAccessStreamHandler.handle_in(
               {activity, [opcode: :text]},
               after_first_activity
             )

    assert after_second_activity.idle_timer != after_first_activity.idle_timer
    refute_receive {:record_activity, "session-rdp-activity", _opts}, 50

    RemoteAccessStreamHandler.terminate(:normal, after_second_activity)
  end

  test "RDP browser owner unmount closes every owner-bound desktop viewer" do
    AuthorizationStub.set_permissions("user-1", ["devices.remote_access.rdp.open"])

    {:ok, state} =
      init_state("session-rdp-unmount",
        protocol: :rdp,
        adapter: :rdp,
        target_port: 3389,
        authorization_module: AuthorizationStub
      )

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in(
        {attach_payload("session-rdp-unmount"), [opcode: :text]},
        state
      )

    assert :ok = RemoteAccessStreamHandler.terminate(:normal, attached)
    assert_receive {:desktop_webrtc_close_all, "session-rdp-unmount", opts}
    assert opts[:scope].user.id == "user-1"
    assert opts[:reason] == "remote_access_stream_normal"
  end

  test "RDP terminal close tears down every desktop viewer" do
    AuthorizationStub.set_permissions("user-1", ["devices.remote_access.rdp.open"])

    {:ok, state} =
      init_state("session-rdp-terminal",
        protocol: :rdp,
        adapter: :rdp,
        target_port: 3389,
        authorization_module: AuthorizationStub
      )

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in(
        {attach_payload("session-rdp-terminal"), [opcode: :text]},
        state
      )

    assert {:stop, :normal, 1000, _frames, closed_state} =
             RemoteAccessStreamHandler.handle_info({:remote_access_closed, "agent_closed"}, attached)

    assert :ok = RemoteAccessStreamHandler.terminate(:normal, closed_state)
    assert_receive {:desktop_webrtc_close_all, "session-rdp-terminal", opts}
    assert opts[:reason] == "remote_access_stream_closed"
  end

  test "RDP stream errors tear down every desktop viewer" do
    AuthorizationStub.set_permissions("user-1", ["devices.remote_access.rdp.open"])

    {:ok, state} =
      init_state("session-rdp-error",
        protocol: :rdp,
        adapter: :rdp,
        target_port: 3389,
        authorization_module: AuthorizationStub
      )

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in(
        {attach_payload("session-rdp-error"), [opcode: :text]},
        state
      )

    assert {:stop, :normal, 1011, _frames, failed_state} =
             RemoteAccessStreamHandler.handle_in(
               {Jason.encode!(%{type: "resize", cols: 10_000, rows: 34}), [opcode: :text]},
               attached
             )

    assert :ok = RemoteAccessStreamHandler.terminate(:normal, failed_state)
    assert_receive {:desktop_webrtc_close_all, "session-rdp-error", opts}
    assert opts[:reason] == "remote_access_stream_failed"
  end

  test "activity messages fail closed for non-RDP sessions" do
    {:ok, state} = init_state("session-ssh-activity")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in(
        {attach_payload("session-ssh-activity"), [opcode: :text]},
        state
      )

    assert {:stop, :normal, 1011, [{:text, response}], failed_state} =
             RemoteAccessStreamHandler.handle_in(
               {Jason.encode!(%{type: "activity", session_id: "session-ssh-activity"}), [opcode: :text]},
               attached
             )

    assert %{"type" => "error", "message" => "Remote access stream failed."} =
             Jason.decode!(response)

    assert failed_state.closing_action == :failed
    assert_receive {:fail_session, "session-ssh-activity", :invalid_request, _opts}
    refute_receive {:record_activity, "session-ssh-activity", _opts}

    RemoteAccessStreamHandler.terminate(:normal, failed_state)
  end

  test "browser frames close the session after permission revocation" do
    AuthorizationStub.set_permissions("user-1", ["devices.remote_access.ssh.open"])
    {:ok, state} = init_state("session-revoked-frame", authorization_module: AuthorizationStub)

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-revoked-frame"), [opcode: :text]}, state)

    AuthorizationStub.set_permissions("user-1", [])

    assert {:stop, :normal, 1008, [{:text, response}], closed_state} =
             RemoteAccessStreamHandler.handle_in(
               {Jason.encode!(%{type: "data", data: Base.encode64("whoami\r")}), [opcode: :text]},
               attached
             )

    assert %{"type" => "error", "message" => "Remote access permission was revoked."} = Jason.decode!(response)
    assert closed_state.closing_action == :revoked
    assert_receive {:request_close, "session-revoked-frame", opts}
    assert opts[:reason] == "permission_revoked"
    refute_receive {:broker_input, _caller, _data}

    RemoteAccessStreamHandler.terminate(:normal, closed_state)
  end

  test "periodic reauthorization closes idle sessions after permission revocation" do
    AuthorizationStub.set_permissions("user-1", ["devices.remote_access.rdp.open"])

    {:ok, state} =
      init_state("session-revoked-periodic",
        authorization_module: AuthorizationStub,
        protocol: :rdp,
        adapter: :rdp,
        target_port: 3389
      )

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-revoked-periodic"), [opcode: :text]}, state)

    assert is_reference(attached.reauth_timer)
    AuthorizationStub.set_permissions("user-1", [])

    assert {:stop, :normal, 1008, [{:text, response}], closed_state} =
             RemoteAccessStreamHandler.handle_info(:reauthorize, attached)

    assert %{"type" => "error", "message" => "Remote access permission was revoked."} = Jason.decode!(response)
    assert closed_state.closing_action == :revoked
    assert_receive {:request_close, "session-revoked-periodic", opts}
    assert opts[:reason] == "permission_revoked"

    RemoteAccessStreamHandler.terminate(:normal, closed_state)
  end

  test "broker output is not released after current permission revocation" do
    AuthorizationStub.set_permissions("user-1", ["devices.remote_access.ssh.open"])
    {:ok, state} = init_state("session-revoked-output", authorization_module: AuthorizationStub)

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-revoked-output"), [opcode: :text]}, state)

    AuthorizationStub.set_permissions("user-1", [])

    assert {:stop, :normal, 1008, [{:text, response}], closed_state} =
             RemoteAccessStreamHandler.handle_info({:remote_access_data, "secret output"}, attached)

    assert %{"type" => "error", "message" => "Remote access permission was revoked."} =
             Jason.decode!(response)

    refute response =~ Base.encode64("secret output")
    assert_receive {:request_close, "session-revoked-output", opts}
    assert opts[:reason] == "permission_revoked"

    RemoteAccessStreamHandler.terminate(:normal, closed_state)
  end

  test "oversized resize frames fail the session without reaching the broker" do
    {:ok, state} = init_state("session-resize-too-large")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-resize-too-large"), [opcode: :text]}, state)

    assert {:stop, :normal, 1011, [{:text, response}], failed_state} =
             RemoteAccessStreamHandler.handle_in(
               {Jason.encode!(%{type: "resize", cols: 10_000, rows: 34}), [opcode: :text]},
               attached
             )

    assert %{"type" => "error", "message" => "Remote access stream failed."} = Jason.decode!(response)
    assert failed_state.closing_action == :failed
    assert_receive {:fail_session, "session-resize-too-large", :invalid_size, _opts}
    refute_receive {:broker_resize, _caller, 10_000, 34}

    RemoteAccessStreamHandler.terminate(:normal, failed_state)
  end

  test "oversized data frames fail the session without reaching the broker" do
    {:ok, state} = init_state("session-data-too-large")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-data-too-large"), [opcode: :text]}, state)

    payload = String.duplicate("x", 65_537)

    assert {:stop, :normal, 1011, [{:text, response}], failed_state} =
             RemoteAccessStreamHandler.handle_in(
               {Jason.encode!(%{type: "data", data: Base.encode64(payload)}), [opcode: :text]},
               attached
             )

    assert %{"type" => "error", "message" => "Remote access stream failed."} = Jason.decode!(response)
    assert failed_state.closing_action == :failed
    assert_receive {:fail_session, "session-data-too-large", :invalid_data_size, _opts}
    refute_receive {:broker_input, _caller, _data}

    RemoteAccessStreamHandler.terminate(:normal, failed_state)
  end

  test "broker output frames expose only terminal data to the browser" do
    {:ok, state} = init_state("session-output")

    {:push, {:text, attach_response}, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-output"), [opcode: :text]}, state)

    refute attach_response =~ "srra_test_ticket"

    assert {:push, {:text, response}, after_data} =
             RemoteAccessStreamHandler.handle_info({:remote_access_data, "shell output\r\n"}, attached)

    assert %{"type" => "data", "data" => encoded_data} = Jason.decode!(response)
    assert Base.decode64!(encoded_data) == "shell output\r\n"
    refute response =~ "srra_test_ticket"
    refute response =~ "credential"
    refute Map.has_key?(Jason.decode!(response), "session")
    assert after_data.attached?

    RemoteAccessStreamHandler.terminate(:normal, after_data)
  end

  test "broker ready frame emits adapter-ready event without secrets" do
    {:ok, state} = init_state("session-ready")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-ready"), [opcode: :text]}, state)

    assert {:push, {:text, response}, ^attached} =
             RemoteAccessStreamHandler.handle_info({:remote_access_ready, "session-ready"}, attached)

    assert %{"type" => "adapter_ready", "session_id" => "session-ready"} = Jason.decode!(response)
    refute response =~ "srra_test_ticket"

    RemoteAccessStreamHandler.terminate(:normal, attached)
  end

  test "broker file-transfer frames are forwarded as typed websocket messages" do
    {:ok, state} = init_state("session-transfer")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-transfer"), [opcode: :text]}, state)

    frame = %{
      session_id: "session-transfer",
      frame_type: "file_transfer_outcome",
      data:
        Jason.encode!(%{
          transfer_id: "transfer-1",
          status: "completed",
          entries: [%{name: "app.log", path: "/var/log/app.log", is_dir: false}]
        })
    }

    assert {:push, {:text, response}, after_transfer} =
             RemoteAccessStreamHandler.handle_info({:remote_access_file_transfer_frame, frame}, attached)

    assert %{
             "type" => "file_transfer",
             "session_id" => "session-transfer",
             "frame_type" => "file_transfer_outcome",
             "payload" => %{
               "transfer_id" => "transfer-1",
               "status" => "completed",
               "entries" => [%{"name" => "app.log"}]
             }
           } = Jason.decode!(response)

    assert after_transfer.attached?
    refute response =~ "srra_test_ticket"
    refute response =~ "credential"

    RemoteAccessStreamHandler.terminate(:normal, after_transfer)
  end

  test "browser file-transfer data frames are forwarded to the broker after attach" do
    {:ok, state} = init_state("session-upload")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-upload"), [opcode: :text]}, state)

    payload = %{
      type: "file_transfer_data",
      transfer_id: "transfer-upload",
      sequence: 1,
      offset: 0,
      data: Base.encode64("hello"),
      eof: false
    }

    assert {:ok, after_data} =
             RemoteAccessStreamHandler.handle_in({Jason.encode!(payload), [opcode: :text]}, attached)

    assert_receive {:broker_file_transfer_data, _caller,
                    %{
                      transfer_id: "transfer-upload",
                      sequence: 1,
                      offset: 0,
                      data: encoded,
                      eof: false
                    }}

    assert Base.decode64!(encoded) == "hello"
    assert after_data.attached?

    RemoteAccessStreamHandler.terminate(:normal, after_data)
  end

  test "browser application request frames are forwarded to the broker after attach" do
    {:ok, state} = init_state("session-app")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-app"), [opcode: :text]}, state)

    payload = %{
      type: "app_request",
      request_id: "request-1",
      method: "GET",
      path: "/health",
      query: "verbose=true",
      headers: %{"accept" => ["text/plain"]}
    }

    assert {:ok, after_request} =
             RemoteAccessStreamHandler.handle_in({Jason.encode!(payload), [opcode: :text]}, attached)

    assert_receive {:broker_application_request, _caller,
                    %{
                      request_id: "request-1",
                      method: "GET",
                      path: "/health",
                      query: "verbose=true",
                      headers: %{"accept" => ["text/plain"]}
                    }}

    assert after_request.attached?

    RemoteAccessStreamHandler.terminate(:normal, after_request)
  end

  test "browser application data frames are forwarded to the broker after attach" do
    {:ok, state} = init_state("session-app-data")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-app-data"), [opcode: :text]}, state)

    payload = %{
      type: "app_data",
      request_id: "request-1",
      sequence: 1,
      data: Base.encode64("body"),
      eof: true
    }

    assert {:ok, after_data} =
             RemoteAccessStreamHandler.handle_in({Jason.encode!(payload), [opcode: :text]}, attached)

    assert_receive {:broker_application_data, _caller,
                    %{
                      request_id: "request-1",
                      direction: "request",
                      sequence: 1,
                      data: encoded,
                      eof: true
                    }}

    assert Base.decode64!(encoded) == "body"
    assert after_data.attached?

    RemoteAccessStreamHandler.terminate(:normal, after_data)
  end

  test "oversized browser application data frames fail without reaching the broker" do
    {:ok, state} = init_state("session-app-data-too-large")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-app-data-too-large"), [opcode: :text]}, state)

    payload = %{
      type: "app_data",
      request_id: "request-1",
      sequence: 1,
      data: Base.encode64(String.duplicate("x", 65_537)),
      eof: true
    }

    assert {:stop, :normal, 1011, [{:text, response}], failed_state} =
             RemoteAccessStreamHandler.handle_in({Jason.encode!(payload), [opcode: :text]}, attached)

    assert %{"type" => "error", "message" => "Remote access stream failed."} = Jason.decode!(response)
    assert failed_state.closing_action == :failed
    assert_receive {:fail_session, "session-app-data-too-large", :invalid_data_size, _opts}
    refute_receive {:broker_application_data, _caller, _payload}

    RemoteAccessStreamHandler.terminate(:normal, failed_state)
  end

  test "browser application request paths reject traversal and malformed forms" do
    invalid_paths = [
      "relative",
      " /health",
      "//admin",
      "/../admin",
      "/safe/./admin",
      "/%2e%2e/admin",
      "/safe\\admin",
      "/safe\x00admin",
      "/%ZZ"
    ]

    for {path, index} <- Enum.with_index(invalid_paths) do
      session_id = "session-app-invalid-path-#{index}"
      {:ok, state} = init_state(session_id)

      {:push, _response, attached} =
        RemoteAccessStreamHandler.handle_in({attach_payload(session_id), [opcode: :text]}, state)

      payload = %{
        type: "app_request",
        request_id: "request-#{index}",
        method: "GET",
        path: path,
        headers: %{"accept" => ["text/plain"]}
      }

      assert {:stop, :normal, 1011, [{:text, response}], failed_state} =
               RemoteAccessStreamHandler.handle_in({Jason.encode!(payload), [opcode: :text]}, attached)

      assert %{"type" => "error", "message" => "Remote access stream failed."} = Jason.decode!(response)
      assert failed_state.closing_action == :failed
      assert_receive {:fail_session, ^session_id, :invalid_request, _opts}
      refute_receive {:broker_application_request, _caller, _payload}

      RemoteAccessStreamHandler.terminate(:normal, failed_state)
    end
  end

  test "broker application frames are forwarded as typed websocket messages" do
    {:ok, state} = init_state("session-app-response")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-app-response"), [opcode: :text]}, state)

    frame = %{
      session_id: "session-app-response",
      frame_type: "app_data",
      data:
        Jason.encode!(%{
          request_id: "request-1",
          session_id: "session-app-response",
          direction: "response",
          sequence: 1,
          data: Base.encode64("pong"),
          eof: true
        })
    }

    assert {:push, {:text, response}, after_frame} =
             RemoteAccessStreamHandler.handle_info({:remote_access_application_frame, frame}, attached)

    assert %{
             "type" => "application",
             "session_id" => "session-app-response",
             "frame_type" => "app_data",
             "payload" => %{
               "request_id" => "request-1",
               "data" => encoded,
               "eof" => true
             }
           } = Jason.decode!(response)

    assert Base.decode64!(encoded) == "pong"
    assert after_frame.attached?
    refute response =~ "srra_test_ticket"
    refute response =~ "credential"

    RemoteAccessStreamHandler.terminate(:normal, after_frame)
  end

  test "browser TCP data frames are forwarded to the broker after attach" do
    {:ok, state} = init_state("session-tcp")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-tcp"), [opcode: :text]}, state)

    payload = %{
      type: "tcp_data",
      connection_id: "session-tcp:tcp",
      sequence: 1,
      data: Base.encode64("ping\n"),
      eof: false
    }

    assert {:ok, after_data} =
             RemoteAccessStreamHandler.handle_in({Jason.encode!(payload), [opcode: :text]}, attached)

    assert_receive {:broker_tcp_data, _caller,
                    %{
                      connection_id: "session-tcp:tcp",
                      direction: "client",
                      sequence: 1,
                      data: encoded,
                      eof: false
                    }}

    assert Base.decode64!(encoded) == "ping\n"
    assert after_data.attached?

    RemoteAccessStreamHandler.terminate(:normal, after_data)
  end

  test "broker TCP frames are forwarded as typed websocket messages" do
    {:ok, state} = init_state("session-tcp-response")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-tcp-response"), [opcode: :text]}, state)

    frame = %{
      session_id: "session-tcp-response",
      frame_type: "tcp_data",
      data:
        Jason.encode!(%{
          session_id: "session-tcp-response",
          connection_id: "session-tcp-response:tcp",
          direction: "upstream",
          sequence: 1,
          data: Base.encode64("pong\n"),
          eof: false
        })
    }

    assert {:push, {:text, response}, after_frame} =
             RemoteAccessStreamHandler.handle_info({:remote_access_tcp_frame, frame}, attached)

    assert %{
             "type" => "tcp",
             "session_id" => "session-tcp-response",
             "frame_type" => "tcp_data",
             "payload" => %{
               "connection_id" => "session-tcp-response:tcp",
               "data" => encoded
             }
           } = Jason.decode!(response)

    assert Base.decode64!(encoded) == "pong\n"
    assert after_frame.attached?
    refute response =~ "srra_test_ticket"
    refute response =~ "credential"

    RemoteAccessStreamHandler.terminate(:normal, after_frame)
  end

  test "idle timeout expires session and renders explicit browser error" do
    {:ok, state} = init_state("session-3")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-3"), [opcode: :text]}, state)

    assert {:stop, :normal, 1000, [{:text, response}], closed_state} =
             RemoteAccessStreamHandler.handle_info(:idle_timeout, attached)

    assert %{"type" => "error", "message" => "Remote access session closed after idle timeout."} =
             Jason.decode!(response)

    assert closed_state.closing_action == :expired
    assert_receive {:expire_session, "session-3", opts}
    assert opts[:reason] == "idle_timeout"

    RemoteAccessStreamHandler.terminate(:normal, closed_state)
    refute_receive {:request_close, "session-3", _opts}
  end

  test "broker close marks session closed and renders close reason" do
    {:ok, state} = init_state("session-4")

    {:push, _response, attached} =
      RemoteAccessStreamHandler.handle_in({attach_payload("session-4"), [opcode: :text]}, state)

    assert {:stop, :normal, 1000, [{:text, response}], closed_state} =
             RemoteAccessStreamHandler.handle_info({:remote_access_closed, "operator_closed"}, attached)

    assert %{"type" => "close", "reason" => "operator_closed"} = Jason.decode!(response)
    assert closed_state.closing_action == :closed
    assert_receive {:close_session, "session-4", opts}
    assert opts[:reason] == "operator_closed"

    RemoteAccessStreamHandler.terminate(:normal, closed_state)
    refute_receive {:request_close, "session-4", _opts}
  end

  defp init_state(session_id, opts \\ []) do
    protocol = Keyword.get(opts, :protocol, :ssh)
    authorization_module = Keyword.get(opts, :authorization_module, AuthorizationStub)

    if !Keyword.has_key?(opts, :authorization_module) do
      permission =
        if protocol == :rdp,
          do: "devices.remote_access.rdp.open",
          else: "devices.remote_access.ssh.open"

      AuthorizationStub.set_permissions("user-1", [permission])
    end

    RemoteAccessStreamHandler.init(
      session_id: session_id,
      scope: %{
        test_pid: self(),
        credential_custody_mode: Keyword.get(opts, :credential_custody_mode, :none),
        credential_rule_id: Keyword.get(opts, :credential_rule_id),
        protocol: protocol,
        adapter: Keyword.get(opts, :adapter, :ssh),
        device_uid: Keyword.get(opts, :device_uid, "linux-1"),
        target_host: Keyword.get(opts, :target_host, "10.0.0.10"),
        target_port: Keyword.get(opts, :target_port, 22),
        session_owner_id: Keyword.get(opts, :session_owner_id, "user-1"),
        identity_claims: Keyword.get(opts, :identity_claims, %{}),
        user:
          Keyword.get(opts, :user, %{
            id: "user-1",
            email: "alice@example.com",
            external_id: "authentik|alice",
            last_auth_method: :oidc,
            permissions: MapSet.new(["devices.remote_access.ssh.open"])
          }),
        session_metadata: Keyword.get(opts, :session_metadata, %{})
      },
      sessions_module: SessionsStub,
      broker_module: BrokerStub,
      credential_grant_resolver: CentralCredentialGrantResolverStub,
      desktop_webrtc_module: DesktopWebRTCStub,
      authorization_module: authorization_module,
      reauth_interval_ms: Keyword.get(opts, :reauth_interval_ms, 30_000)
    )
  end

  defp attach_payload(session_id) do
    Jason.encode!(%{
      type: "attach",
      ticket: "srra_test_ticket",
      session_id: session_id,
      cols: 132,
      rows: 43
    })
  end
end
