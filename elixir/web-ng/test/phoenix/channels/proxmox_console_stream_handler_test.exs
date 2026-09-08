defmodule ServiceRadarWebNGWeb.Channels.ProxmoxConsoleStreamHandlerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Channels.ProxmoxConsoleStreamHandler

  @moduletag :db_free

  @console_permissions ["devices.console.open", "devices.console.credentials.use"]

  defmodule SessionsStub do
    @moduledoc false

    def attach_with_ticket(ticket, opts) do
      send(test_pid(opts), {:attach_with_ticket, ticket, opts})

      session =
        apply_session_overrides(
          %ProxmoxConsoleSession{
            id: opts[:session_id],
            device_uid: "pve-1",
            target_kind: :pve_host,
            console_mode: :ssh,
            agent_id: "agent-1",
            gateway_id: "gateway-1",
            credential_rule_id: Ecto.UUID.generate(),
            status: :attached,
            ticket_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
            idle_timeout_seconds: 30,
            absolute_timeout_seconds: 120,
            metadata: %{"test_pid" => test_pid(opts)},
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          },
          Map.get(opts[:scope].identity_claims, :session_overrides, %{})
        )

      {:ok, session}
    end

    def request_close(session_id, opts) do
      send(test_pid(opts), {:request_close, session_id, opts})
      {:ok, %ProxmoxConsoleSession{id: session_id, status: :closing}}
    end

    def close_session(session_id, opts) do
      send(test_pid(opts), {:close_session, session_id, opts})
      {:ok, %ProxmoxConsoleSession{id: session_id, status: :closed}}
    end

    def expire_session(session_id, opts) do
      send(test_pid(opts), {:expire_session, session_id, opts})
      {:ok, %ProxmoxConsoleSession{id: session_id, status: :expired}}
    end

    def fail_session(session_id, reason, opts) do
      send(test_pid(opts), {:fail_session, session_id, reason, opts})
      {:ok, %ProxmoxConsoleSession{id: session_id, status: :failed}}
    end

    defp test_pid(opts), do: opts |> Keyword.fetch!(:scope) |> Map.fetch!(:identity_claims) |> Map.fetch!(:test_pid)

    defp apply_session_overrides(session, overrides) when is_map(overrides) do
      metadata =
        session.metadata
        |> Map.merge(Map.get(overrides, :metadata, %{}))
        |> Map.merge(Map.get(overrides, "metadata", %{}))

      overrides =
        overrides
        |> Map.drop([:metadata, "metadata"])
        |> Map.new(&normalize_override/1)
        |> Map.reject(fn {key, _value} -> is_nil(key) end)

      session
      |> struct(overrides)
      |> Map.put(:metadata, metadata)
    end

    defp apply_session_overrides(session, _overrides), do: session

    defp normalize_override({key, value}) when key in [:device_uid, :target_kind, :console_mode], do: {key, value}

    defp normalize_override({"device_uid", value}), do: {:device_uid, value}
    defp normalize_override({"target_kind", value}), do: {:target_kind, value}
    defp normalize_override({"console_mode", value}), do: {:console_mode, value}
    defp normalize_override({_key, _value}), do: {nil, nil}
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

  defmodule AuthorizationStub do
    @moduledoc false

    def authorize_current(%Scope{user: %{id: id}} = scope, required_permissions) do
      current_permissions = Process.get({__MODULE__, id}, MapSet.new())

      if Enum.all?(required_permissions, &MapSet.member?(current_permissions, &1)) do
        {:ok, %{scope | permissions: current_permissions}}
      else
        {:error, :permission_revoked}
      end
    end

    def authorize_current(_scope, _required_permissions), do: {:error, :permission_revoked}

    def set_permissions(user_id, permissions) do
      Process.put({__MODULE__, user_id}, MapSet.new(permissions))
    end
  end

  test "attach consumes ticket, starts broker, and does not echo ticket" do
    {:ok, state} = init_state("session-1")

    assert {:push, {:text, response}, attached} =
             ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-1"), [opcode: :text]}, state)

    assert %{"type" => "ready", "session_id" => "session-1"} = Jason.decode!(response)
    refute response =~ "srpve_test_ticket"
    assert attached.attached?
    assert is_reference(attached.idle_timer)
    assert is_reference(attached.absolute_timer)
    assert_receive {:attach_with_ticket, "srpve_test_ticket", _opts}
    assert_receive {:broker_started, "session-1", opts}
    assert opts[:cols] == 132
    assert opts[:rows] == 43

    ProxmoxConsoleStreamHandler.terminate(:normal, attached)
  end

  test "rejected attach does not echo the supplied ticket" do
    {:ok, state} = init_state("session-reject")

    supplied_ticket = "srpve_secret_ticket_value"

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: supplied_ticket,
        session_id: "wrong-session"
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             ProxmoxConsoleStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "Invalid or expired console ticket."} =
             Jason.decode!(response)

    refute response =~ supplied_ticket
  end

  test "attach requires both console-open and console-credential-use permissions" do
    {:ok, state} = init_state("session-missing-credential-use", %{}, ["devices.console.open"])

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             ProxmoxConsoleStreamHandler.handle_in(
               {attach_payload("session-missing-credential-use"), [opcode: :text]},
               state
             )

    assert %{"type" => "error", "message" => "Invalid or expired console ticket."} =
             Jason.decode!(response)

    refute_receive {:attach_with_ticket, _ticket, _opts}
    refute_receive {:broker_started, _session_id, _opts}
  end

  test "attach rejects oversized terminal dimensions before broker start" do
    {:ok, state} = init_state("session-oversized-attach")

    payload =
      Jason.encode!(%{
        type: "attach",
        ticket: "srpve_test_ticket",
        session_id: "session-oversized-attach",
        cols: 10_000,
        rows: 43
      })

    assert {:stop, :normal, 1008, [{:text, response}], ^state} =
             ProxmoxConsoleStreamHandler.handle_in({payload, [opcode: :text]}, state)

    assert %{"type" => "error", "message" => "Invalid console terminal dimensions."} =
             Jason.decode!(response)

    assert_receive {:fail_session, "session-oversized-attach", :invalid_size, _opts}
    refute_receive {:broker_started, "session-oversized-attach", _opts}
  end

  test "data and resize frames forward to broker and refresh idle timer" do
    {:ok, state} = init_state("session-2")

    {:push, _response, attached} =
      ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-2"), [opcode: :text]}, state)

    original_timer = attached.idle_timer

    assert {:ok, after_data} =
             ProxmoxConsoleStreamHandler.handle_in(
               {Jason.encode!(%{type: "data", data: Base.encode64("whoami\r")}), [opcode: :text]},
               attached
             )

    assert_receive {:broker_input, _caller, "whoami\r"}
    assert after_data.idle_timer != original_timer

    assert {:ok, after_resize} =
             ProxmoxConsoleStreamHandler.handle_in(
               {Jason.encode!(%{type: "resize", cols: 120, rows: 34}), [opcode: :text]},
               after_data
             )

    assert_receive {:broker_resize, _caller, 120, 34}
    assert after_resize.idle_timer != after_data.idle_timer

    ProxmoxConsoleStreamHandler.terminate(:normal, after_resize)
  end

  test "oversized resize frames fail the session without reaching the broker" do
    {:ok, state} = init_state("session-resize-too-large")

    {:push, _response, attached} =
      ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-resize-too-large"), [opcode: :text]}, state)

    assert {:stop, :normal, 1011, [{:text, response}], failed_state} =
             ProxmoxConsoleStreamHandler.handle_in(
               {Jason.encode!(%{type: "resize", cols: 10_000, rows: 34}), [opcode: :text]},
               attached
             )

    assert %{"type" => "error", "message" => "Proxmox console stream failed."} = Jason.decode!(response)
    assert failed_state.closing_action == :failed
    assert_receive {:fail_session, "session-resize-too-large", :invalid_size, _opts}
    refute_receive {:broker_resize, _caller, 10_000, 34}

    ProxmoxConsoleStreamHandler.terminate(:normal, failed_state)
  end

  test "oversized data frames fail the session without reaching the broker" do
    {:ok, state} = init_state("session-data-too-large")

    {:push, _response, attached} =
      ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-data-too-large"), [opcode: :text]}, state)

    payload = String.duplicate("x", 65_537)

    assert {:stop, :normal, 1011, [{:text, response}], failed_state} =
             ProxmoxConsoleStreamHandler.handle_in(
               {Jason.encode!(%{type: "data", data: Base.encode64(payload)}), [opcode: :text]},
               attached
             )

    assert %{"type" => "error", "message" => "Proxmox console stream failed."} = Jason.decode!(response)
    assert failed_state.closing_action == :failed
    assert_receive {:fail_session, "session-data-too-large", :invalid_data_size, _opts}
    refute_receive {:broker_input, _caller, _data}

    ProxmoxConsoleStreamHandler.terminate(:normal, failed_state)
  end

  test "broker output frames expose only terminal data to the browser" do
    {:ok, state} = init_state("session-output")

    {:push, {:text, attach_response}, attached} =
      ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-output"), [opcode: :text]}, state)

    refute attach_response =~ "srpve_test_ticket"

    assert {:push, {:text, response}, after_data} =
             ProxmoxConsoleStreamHandler.handle_info({:proxmox_console_data, "shell output\r\n"}, attached)

    assert %{"type" => "data", "data" => encoded_data} = Jason.decode!(response)
    assert Base.decode64!(encoded_data) == "shell output\r\n"
    refute response =~ "srpve_test_ticket"
    refute response =~ "credential"
    refute Map.has_key?(Jason.decode!(response), "session")
    assert after_data.attached?

    ProxmoxConsoleStreamHandler.terminate(:normal, after_data)
  end

  test "current permission contraction blocks browser input and broker output" do
    {:ok, state} = init_state("session-revoked")

    {:push, _response, attached} =
      ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-revoked"), [opcode: :text]}, state)

    AuthorizationStub.set_permissions("console-user", [])

    assert {:stop, :normal, 1008, [{:text, input_response}], input_closed} =
             ProxmoxConsoleStreamHandler.handle_in(
               {Jason.encode!(%{type: "data", data: Base.encode64("whoami\r")}), [opcode: :text]},
               attached
             )

    assert %{"type" => "error", "message" => "Proxmox console permission was revoked."} =
             Jason.decode!(input_response)

    refute_receive {:broker_input, _caller, _data}
    assert_receive {:request_close, "session-revoked", input_opts}
    assert input_opts[:reason] == "permission_revoked"
    ProxmoxConsoleStreamHandler.terminate(:normal, input_closed)

    {:ok, output_state} = init_state("session-revoked-output")

    {:push, _response, output_attached} =
      ProxmoxConsoleStreamHandler.handle_in(
        {attach_payload("session-revoked-output"), [opcode: :text]},
        output_state
      )

    AuthorizationStub.set_permissions("console-user", [])

    assert {:stop, :normal, 1008, [{:text, output_response}], output_closed} =
             ProxmoxConsoleStreamHandler.handle_info(
               {:proxmox_console_data, "secret console output"},
               output_attached
             )

    refute output_response =~ Base.encode64("secret console output")
    assert_receive {:request_close, "session-revoked-output", _opts}
    ProxmoxConsoleStreamHandler.terminate(:normal, output_closed)
  end

  test "periodic current-authority check closes an idle console after revocation" do
    {:ok, state} = init_state("session-periodic-revoked")

    {:push, _response, attached} =
      ProxmoxConsoleStreamHandler.handle_in(
        {attach_payload("session-periodic-revoked"), [opcode: :text]},
        state
      )

    assert is_reference(attached.reauth_timer)
    AuthorizationStub.set_permissions("console-user", [])

    assert {:stop, :normal, 1008, [{:text, _response}], closed} =
             ProxmoxConsoleStreamHandler.handle_info(:reauthorize, attached)

    assert_receive {:request_close, "session-periodic-revoked", _opts}
    ProxmoxConsoleStreamHandler.terminate(:normal, closed)
  end

  test "generic SSH and Proxmox guest targets attach through the same broker path" do
    targets = [
      {"generic-ssh-session",
       %{
         device_uid: "linux-1",
         target_kind: :pve_host,
         console_mode: :ssh,
         metadata: %{
           "remote_console" => %{
             "schema" => "serviceradar.remote_console_target.v1",
             "provider" => "generic",
             "target_ref" => "generic:device:linux-1",
             "target_type" => "device",
             "protocol" => "ssh",
             "transport" => "pty",
             "agent_id" => "agent-1"
           }
         }
       }},
      {"proxmox-guest-session",
       %{
         device_uid: "pve-vm-100",
         target_kind: :qemu_guest,
         console_mode: :proxmox_vncwebsocket,
         metadata: %{
           "remote_console" => %{
             "schema" => "serviceradar.remote_console_target.v1",
             "provider" => "proxmox",
             "target_ref" => "proxmox:guest:pve-a:qemu:100",
             "target_type" => "guest",
             "protocol" => "vnc",
             "transport" => "framebuffer",
             "agent_id" => "agent-1"
           }
         }
       }}
    ]

    for {session_id, overrides} <- targets do
      {:ok, state} = init_state(session_id, overrides)

      assert {:push, {:text, response}, attached} =
               ProxmoxConsoleStreamHandler.handle_in({attach_payload(session_id), [opcode: :text]}, state)

      assert %{"type" => "ready", "session_id" => ^session_id} = Jason.decode!(response)
      assert_receive {:broker_started, ^session_id, opts}
      assert opts[:cols] == 132
      assert opts[:rows] == 43
      assert attached.session.metadata["remote_console"]["schema"] == "serviceradar.remote_console_target.v1"

      ProxmoxConsoleStreamHandler.terminate(:normal, attached)
    end
  end

  test "idle timeout expires session and renders explicit browser error" do
    {:ok, state} = init_state("session-3")

    {:push, _response, attached} =
      ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-3"), [opcode: :text]}, state)

    assert {:stop, :normal, 1000, [{:text, response}], closed_state} =
             ProxmoxConsoleStreamHandler.handle_info(:idle_timeout, attached)

    assert %{"type" => "error", "message" => "Console session closed after idle timeout."} =
             Jason.decode!(response)

    assert closed_state.closing_action == :expired
    assert_receive {:expire_session, "session-3", opts}
    assert opts[:reason] == "idle_timeout"

    ProxmoxConsoleStreamHandler.terminate(:normal, closed_state)
    refute_receive {:request_close, "session-3", _opts}
  end

  test "absolute timeout expires session and renders explicit browser error" do
    {:ok, state} = init_state("session-absolute")

    {:push, _response, attached} =
      ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-absolute"), [opcode: :text]}, state)

    assert {:stop, :normal, 1000, [{:text, response}], closed_state} =
             ProxmoxConsoleStreamHandler.handle_info(:absolute_timeout, attached)

    assert %{"type" => "error", "message" => "Console session reached its maximum duration."} =
             Jason.decode!(response)

    assert closed_state.closing_action == :expired
    assert_receive {:expire_session, "session-absolute", opts}
    assert opts[:reason] == "absolute_timeout"

    ProxmoxConsoleStreamHandler.terminate(:normal, closed_state)
    refute_receive {:request_close, "session-absolute", _opts}
  end

  test "broker close marks session closed and renders close reason" do
    {:ok, state} = init_state("session-4")

    {:push, _response, attached} =
      ProxmoxConsoleStreamHandler.handle_in({attach_payload("session-4"), [opcode: :text]}, state)

    assert {:stop, :normal, 1000, [{:text, response}], closed_state} =
             ProxmoxConsoleStreamHandler.handle_info({:proxmox_console_closed, "operator_closed"}, attached)

    assert %{"type" => "close", "reason" => "operator_closed"} = Jason.decode!(response)
    assert closed_state.closing_action == :closed
    assert_receive {:close_session, "session-4", opts}
    assert opts[:reason] == "operator_closed"

    ProxmoxConsoleStreamHandler.terminate(:normal, closed_state)
    refute_receive {:request_close, "session-4", _opts}
  end

  defp init_state(session_id, session_overrides \\ %{}, permissions \\ @console_permissions) do
    AuthorizationStub.set_permissions("console-user", permissions)

    scope =
      Scope.for_user(
        %{id: "console-user", email: "console-user@example.test", role: :viewer},
        permissions: MapSet.new(permissions),
        identity_claims: %{test_pid: self(), session_overrides: session_overrides}
      )

    ProxmoxConsoleStreamHandler.init(
      session_id: session_id,
      scope: scope,
      sessions_module: SessionsStub,
      broker_module: BrokerStub,
      authorization_module: AuthorizationStub
    )
  end

  defp attach_payload(session_id) do
    Jason.encode!(%{
      type: "attach",
      ticket: "srpve_test_ticket",
      session_id: session_id,
      cols: 132,
      rows: 43
    })
  end
end
