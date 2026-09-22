defmodule ServiceRadar.Edge.RemoteAccessBrokerClientTest do
  @moduledoc """
  Guards the broker's client boundary against a broker that is already gone.

  The browser-facing WebSocket process calls these functions inline from
  `handle_in/2`. A bare `GenServer.call` there turns the broker's ordinary
  shutdown into an exit in the caller, which kills the whole WebSocket
  connection before the queued close reason can be delivered to the browser.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessBroker

  describe "calls against a broker that is shutting down" do
    test "resize/3 reports the broker as unavailable when it stops mid-call" do
      broker = stop_on_call(:normal)

      assert {:error, :broker_unavailable} = RemoteAccessBroker.resize(broker, 126, 39)
    end

    test "resize/3 reports the broker as unavailable when it is already gone" do
      broker = dead_process()

      assert {:error, :broker_unavailable} = RemoteAccessBroker.resize(broker, 126, 39)
    end

    test "send_input/2 reports the broker as unavailable when it stops mid-call" do
      broker = stop_on_call(:normal)

      assert {:error, :broker_unavailable} = RemoteAccessBroker.send_input(broker, "ls\n")
    end

    test "an orderly shutdown reason is also reported as unavailable" do
      broker = stop_on_call(:shutdown)

      assert {:error, :broker_unavailable} = RemoteAccessBroker.send_input(broker, "ls\n")
    end

    test "a broker crash is reported as a failed call rather than exiting the caller" do
      broker = stop_on_call(:boom)

      assert {:error, :broker_call_failed} = RemoteAccessBroker.resize(broker, 126, 39)
    end

    test "every browser-driven send reports a stopping broker instead of exiting" do
      assert {:error, :broker_unavailable} =
               RemoteAccessBroker.send_application_request(stop_on_call(:normal), %{})

      assert {:error, :broker_unavailable} =
               RemoteAccessBroker.send_application_data(stop_on_call(:normal), %{})

      assert {:error, :broker_unavailable} =
               RemoteAccessBroker.send_tcp_data(stop_on_call(:normal), %{})

      assert {:error, :broker_unavailable} =
               RemoteAccessBroker.send_desktop_control(stop_on_call(:normal), %{})

      assert {:error, :broker_unavailable} =
               RemoteAccessBroker.send_file_transfer_data(stop_on_call(:normal), %{})
    end
  end

  describe "calls against a live broker" do
    test "the broker's own reply is returned untouched" do
      broker = reply_on_call({:error, :frame_rejected})

      assert {:error, :frame_rejected} = RemoteAccessBroker.resize(broker, 126, 39)
    end
  end

  # Accepts one call and then stops with `reason` without replying, which is the
  # shape of a broker that receives the agent's error frame while a browser
  # resize is already in flight.
  defp stop_on_call(reason) do
    spawn(fn ->
      receive do
        {:"$gen_call", _from, _request} -> if reason != :normal, do: exit(reason)
      end
    end)
  end

  defp reply_on_call(reply) do
    spawn(fn ->
      receive do
        {:"$gen_call", from, _request} -> GenServer.reply(from, reply)
      end
    end)
  end

  defp dead_process do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end
end
