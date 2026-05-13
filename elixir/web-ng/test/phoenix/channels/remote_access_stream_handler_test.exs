defmodule ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandlerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandler

  defmodule SessionsStub do
    @moduledoc false

    def attach_with_ticket(ticket, opts) do
      send(test_pid(opts), {:attach_with_ticket, ticket, opts})

      {:ok,
       %RemoteAccessSession{
         id: opts[:session_id],
         device_uid: "linux-1",
         target_kind: :inventory_device,
         target_host: "10.0.0.10",
         target_port: 22,
         protocol: :ssh,
         adapter: :ssh,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         credential_rule_id: scope_value(opts, :credential_rule_id, nil),
         credential_custody_mode: opts |> Keyword.fetch!(:scope) |> Map.get(:credential_custody_mode, :ssh_certificate),
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

    defp test_pid(opts), do: opts |> Keyword.fetch!(:scope) |> Map.fetch!(:test_pid)

    defp scope_value(opts, key, default) do
      opts
      |> Keyword.fetch!(:scope)
      |> Map.get(key, default)
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
        identity_claims: %{"groups" => ["linux-admins"]},
        session_metadata: %{
          "ssh_principal_mappings" => [
            %{"source" => "groups", "value" => "linux-admins", "principals" => ["ubuntu"]}
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
          username: "root",
          public_key: "ssh-ed25519 AAAATEST user@workstation",
          private_key: "session-private-key",
          passphrase: "session-passphrase",
          requested_principals: ["ubuntu"]
        }
      })

    assert {:push, {:text, response}, attached} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "ready", "session_id" => "session-cert"} = Jason.decode!(response)
    refute response =~ "session-private-key"
    refute response =~ "session-passphrase"
    refute response =~ "AAAATEST"

    assert_receive {:sign_user_certificate, sign_request}
    assert sign_request.principals == ["ubuntu"]
    assert sign_request.ttl_seconds == 900

    assert_receive {:broker_started, "session-cert", opts}
    assert opts[:ssh_certificate].credential_mode == "ssh_certificate"
    assert opts[:ssh_certificate].ssh["username"] == "ubuntu"
    assert opts[:ssh_certificate].ssh["certificate"] =~ "ssh-ed25519-cert-v01@openssh.com"
    assert opts[:metadata]["ssh"]["private_key"] == "session-private-key"
    assert opts[:metadata]["ssh"]["passphrase"] == "session-passphrase"

    refute inspect(sign_request) =~ "browser-admins"
    refute inspect(sign_request) =~ "session-private-key"

    RemoteAccessStreamHandler.terminate(:normal, attached)
  end

  test "ssh certificate attach rejects browser-supplied identity policy fields" do
    {:ok, state} =
      init_state("session-cert-policy-fields",
        credential_custody_mode: :ssh_certificate,
        identity_claims: %{"groups" => ["linux-admins"]},
        session_metadata: %{
          "ssh_principal_mappings" => [
            %{"source" => "groups", "value" => "linux-admins", "principals" => ["ubuntu"]}
          ]
        }
      )

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srra_test_ticket",
        session_id: "session-cert-policy-fields",
        credential: %{
          public_key: "ssh-ed25519 AAAATEST user@workstation",
          private_key: "session-private-key",
          requested_principals: ["ubuntu"],
          claims: %{"groups" => ["browser-admins"]}
        }
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             RemoteAccessStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "The supplied SSH credential was rejected by policy."} =
             Jason.decode!(response)

    assert_receive {:fail_session, "session-cert-policy-fields", :credential_policy_denied, _opts}
    refute response =~ "browser-admins"
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
    RemoteAccessStreamHandler.init(
      session_id: session_id,
      scope: %{
        test_pid: self(),
        credential_custody_mode: Keyword.get(opts, :credential_custody_mode, :none),
        credential_rule_id: Keyword.get(opts, :credential_rule_id),
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
      credential_grant_resolver: CentralCredentialGrantResolverStub
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
