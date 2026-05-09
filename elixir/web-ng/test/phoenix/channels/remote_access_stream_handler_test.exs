defmodule ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandlerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSession
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
         credential_custody_mode: opts |> Keyword.fetch!(:scope) |> Map.get(:credential_custody_mode, :ssh_certificate),
         rbac_decision: :allowed,
         status: :attached,
         attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
         idle_timeout_seconds: 30,
         absolute_timeout_seconds: 120,
         metadata: %{"test_pid" => test_pid(opts)},
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
        credential_custody_mode: Keyword.get(opts, :credential_custody_mode, :ssh_certificate)
      },
      sessions_module: SessionsStub,
      broker_module: BrokerStub
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
