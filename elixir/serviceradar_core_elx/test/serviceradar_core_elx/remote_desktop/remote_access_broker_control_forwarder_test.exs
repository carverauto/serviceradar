defmodule ServiceRadarCoreElx.RemoteDesktop.RemoteAccessBrokerControlForwarderTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.RemoteDesktop.RemoteAccessBrokerControlForwarder

  defmodule BrokerRegistryStub do
    @moduledoc false

    def lookup(session_id) do
      send(test_pid(), {:broker_lookup, session_id})

      case Application.get_env(:serviceradar_core_elx, :remote_desktop_forwarder_broker) do
        nil -> {:error, :broker_not_found}
        broker -> {:ok, broker, %{agent_id: "agent-1"}}
      end
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_forwarder_test_pid)
    end
  end

  defmodule BrokerStub do
    @moduledoc false

    def send_desktop_control(broker, frame) do
      send(test_pid(), {:broker_desktop_control, broker, frame})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_forwarder_test_pid)
    end
  end

  setup do
    previous_pid = Application.get_env(:serviceradar_core_elx, :remote_desktop_forwarder_test_pid)

    previous_broker =
      Application.get_env(:serviceradar_core_elx, :remote_desktop_forwarder_broker)

    Application.put_env(:serviceradar_core_elx, :remote_desktop_forwarder_test_pid, self())

    on_exit(fn ->
      restore_env(:remote_desktop_forwarder_test_pid, previous_pid)
      restore_env(:remote_desktop_forwarder_broker, previous_broker)
    end)

    :ok
  end

  test "forwards browser desktop control frames to the active broker" do
    Application.put_env(:serviceradar_core_elx, :remote_desktop_forwarder_broker, self())

    frame = %{
      "session_id" => "rdp-session-1",
      "protocol" => "rdp",
      "frame_type" => "desktop.input",
      "input" => %{"kind" => "key", "key" => "Enter", "down" => true}
    }

    assert :ok =
             RemoteAccessBrokerControlForwarder.forward_browser_control(
               %{session_id: "rdp-session-1"},
               "viewer-1",
               frame,
               broker_registry: BrokerRegistryStub,
               broker_module: BrokerStub
             )

    assert_receive {:broker_lookup, "rdp-session-1"}
    assert_receive {:broker_desktop_control, broker, ^frame}
    assert broker == self()
  end

  test "fails closed when no active broker is registered for the session" do
    frame = %{
      "session_id" => "rdp-session-missing",
      "protocol" => "rdp",
      "frame_type" => "desktop.resize",
      "width" => 1280,
      "height" => 720
    }

    assert {:error, :broker_not_found} =
             RemoteAccessBrokerControlForwarder.forward_browser_control(
               %{session_id: "rdp-session-missing"},
               "viewer-1",
               frame,
               broker_registry: BrokerRegistryStub,
               broker_module: BrokerStub
             )

    assert_receive {:broker_lookup, "rdp-session-missing"}
    refute_receive {:broker_desktop_control, _broker, _frame}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
