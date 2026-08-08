defmodule ServiceRadarAgentGateway.DesktopMediaCloseReconcilerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.DesktopMediaCloseReconciler
  alias ServiceRadarAgentGateway.DesktopMediaSessionTracker
  alias ServiceRadarAgentGateway.TestSupport.DesktopMediaFrameForwarderStub

  @moduletag :requires_app

  setup do
    previous_result =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_frame_forwarder_close_result)

    previous_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_server_test_pid)

    previous_state = :sys.get_state(DesktopMediaSessionTracker)

    :sys.replace_state(DesktopMediaSessionTracker, fn state ->
      Map.put(state, :sessions, %{})
    end)

    Application.put_env(:serviceradar_agent_gateway, :desktop_media_server_test_pid, self())

    on_exit(fn ->
      :sys.replace_state(DesktopMediaSessionTracker, fn _state -> previous_state end)
      restore_env(:desktop_media_frame_forwarder_close_result, previous_result)
      restore_env(:desktop_media_server_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "a restarted supervised reconciler completes retained cleanup idempotently" do
    assert {:ok, session} = DesktopMediaSessionTracker.open_session(session_attrs())

    assert {:ok, %{pending_core_cleanup: true}} =
             DesktopMediaSessionTracker.mark_closing(
               session.desktop_session_id,
               session.media_session_id,
               session.agent_id,
               %{media_ingest_id: session.media_ingest_id, pending_core_cleanup: true}
             )

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder_close_result,
      {:error, :core_unavailable}
    )

    name = :desktop_media_close_reconciler_test

    pid =
      start_supervised!(
        {DesktopMediaCloseReconciler,
         name: name,
         interval_ms: :disabled,
         tracker: DesktopMediaSessionTracker,
         forwarder: DesktopMediaFrameForwarderStub}
      )

    assert {:ok, 0} = DesktopMediaCloseReconciler.reconcile_now(name)
    assert [_pending] = DesktopMediaSessionTracker.pending_core_cleanups()

    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    restarted = wait_for_restarted(name, pid)
    assert is_pid(restarted)

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder_close_result,
      :ok
    )

    assert {:ok, 1} = DesktopMediaCloseReconciler.reconcile_now(name)
    assert DesktopMediaSessionTracker.pending_core_cleanups() == []
    assert DesktopMediaSessionTracker.fetch_session(session.desktop_session_id) == nil

    assert {:ok, 0} = DesktopMediaCloseReconciler.reconcile_now(name)
  end

  defp session_attrs do
    %{
      desktop_session_id: "desktop-reconcile-1",
      media_session_id: "media-reconcile-1",
      media_ingest_id: "ingest-reconcile-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition_id: "default",
      target_id: "target-1",
      route_id: "route-1",
      lease_token: "lease-1"
    }
  end

  defp wait_for_restarted(name, previous_pid, attempts \\ 50)

  defp wait_for_restarted(_name, _previous_pid, 0), do: nil

  defp wait_for_restarted(name, previous_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous_pid ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_restarted(name, previous_pid, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
