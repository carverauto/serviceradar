defmodule ServiceRadarCoreElx.DesktopMediaIngressTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.DesktopMediaIngress
  alias ServiceRadarCoreElx.DesktopMediaIngressSupervisor
  alias ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager

  defmodule OfferProviderStub do
    @moduledoc false

    def add_webrtc_viewer(_session_id, _viewer_session_id, _signaling, _opts), do: :ok

    def remove_webrtc_viewer(session_id, viewer_session_id, _opts) do
      send(
        Application.fetch_env!(:serviceradar_core_elx, :desktop_media_ingress_test_pid),
        {:offer_provider_remove_viewer, session_id, viewer_session_id}
      )

      :ok
    end
  end

  setup do
    previous_test_pid =
      Application.get_env(:serviceradar_core_elx, :desktop_media_ingress_test_pid)

    Application.put_env(:serviceradar_core_elx, :desktop_media_ingress_test_pid, self())
    clear_ingress_sessions()
    reset_media_manager()

    on_exit(fn ->
      clear_ingress_sessions()
      reset_media_manager()
      restore_env(:desktop_media_ingress_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "starts a session ingress process and acknowledges bound frames" do
    session = session("desktop-ingress-1")

    assert {:ok,
            %Desktopmedia.DesktopMediaAck{
              desktop_session_id: "desktop-ingress-1",
              media_session_id: "media-desktop-ingress-1",
              media_ingest_id: "ingest-desktop-ingress-1",
              gateway_id: "gateway-1",
              last_accepted_sequence: 9,
              credit_bytes: 0,
              pause: true
            }} =
             DesktopMediaIngress.forward_frame(frame("desktop-ingress-1", sequence: 9, payload: <<1, 2, 3, 4>>), session)

    assert [{_, ingress_pid, _, _}] = DynamicSupervisor.which_children(DesktopMediaIngressSupervisor)
    assert is_pid(ingress_pid)

    assert {:ok, %Desktopmedia.DesktopMediaAck{last_accepted_sequence: 10, credit_bytes: 0, pause: true}} =
             DesktopMediaIngress.forward_frame(frame("desktop-ingress-1", sequence: 10), session)

    assert [{_, ^ingress_pid, _, _}] = DynamicSupervisor.which_children(DesktopMediaIngressSupervisor)

    assert %{
             viewer_count: 0,
             last_sequence: 10,
             forwarded_bytes: 7,
             forwarded_frames: 2
           } = MediaSessionManager.fetch_session("desktop-ingress-1")
  end

  test "gateway owner loss stops idle ingress and closes orphaned viewers" do
    desktop_session_id = "desktop-ingress-idle-1"
    session = session(desktop_session_id)

    assert :ok =
             MediaSessionManager.add_webrtc_viewer(
               desktop_session_id,
               "viewer-owner-loss-1",
               %{pid: self()},
               offer_provider: OfferProviderStub,
               transport: "webrtc_desktop_media"
             )

    assert {:ok, %Desktopmedia.DesktopMediaAck{}} =
             DesktopMediaIngress.forward_frame(frame(desktop_session_id, sequence: 1), session, idle_timeout_ms: 10)

    assert [{_, ingress_pid, _, _}] = DynamicSupervisor.which_children(DesktopMediaIngressSupervisor)
    monitor_ref = Process.monitor(ingress_pid)

    assert_receive {:DOWN, ^monitor_ref, :process, ^ingress_pid, :normal}, 250
    assert_receive {:offer_provider_remove_viewer, ^desktop_session_id, "viewer-owner-loss-1"}
    assert DynamicSupervisor.count_children(DesktopMediaIngressSupervisor).active == 0
    assert MediaSessionManager.fetch_session(desktop_session_id) == nil
  end

  test "terminal cleanup stops ingress and deletes media accounting immediately" do
    desktop_session_id = "desktop-ingress-terminal-1"
    session = session(desktop_session_id)

    assert {:ok, %Desktopmedia.DesktopMediaAck{}} =
             DesktopMediaIngress.forward_frame(frame(desktop_session_id, sequence: 1), session)

    assert DynamicSupervisor.count_children(DesktopMediaIngressSupervisor).active == 1
    assert %{viewer_count: 0} = MediaSessionManager.fetch_session(desktop_session_id)

    assert :ok = DesktopMediaIngress.close_session(desktop_session_id)
    assert DynamicSupervisor.count_children(DesktopMediaIngressSupervisor).active == 0
    assert MediaSessionManager.fetch_session(desktop_session_id) == nil
    assert :ok = DesktopMediaIngress.close_session(desktop_session_id)
  end

  test "repeated unique terminal sessions leave no ingress actors or media state" do
    desktop_session_ids = Enum.map(1..25, &"desktop-ingress-no-leak-#{&1}")

    Enum.each(desktop_session_ids, fn desktop_session_id ->
      assert {:ok, %Desktopmedia.DesktopMediaAck{}} =
               DesktopMediaIngress.forward_frame(
                 frame(desktop_session_id, sequence: 1),
                 session(desktop_session_id)
               )
    end)

    assert DynamicSupervisor.count_children(DesktopMediaIngressSupervisor).active == 25

    Enum.each(desktop_session_ids, fn desktop_session_id ->
      assert :ok = DesktopMediaIngress.close_session(desktop_session_id)
    end)

    assert DynamicSupervisor.count_children(DesktopMediaIngressSupervisor).active == 0

    Enum.each(desktop_session_ids, fn desktop_session_id ->
      assert MediaSessionManager.fetch_session(desktop_session_id) == nil
    end)
  end

  test "rejects unbound frames without mutating the live session" do
    session = session("desktop-ingress-mismatch-1")

    assert {:ok, %Desktopmedia.DesktopMediaAck{last_accepted_sequence: 1}} =
             DesktopMediaIngress.forward_frame(frame("desktop-ingress-mismatch-1", sequence: 1), session)

    assert {:error, :media_session_mismatch} =
             DesktopMediaIngress.forward_frame(
               %{
                 frame("desktop-ingress-mismatch-1", sequence: 2)
                 | media_session_id: "media-other"
               },
               session
             )

    assert {:ok, %Desktopmedia.DesktopMediaAck{last_accepted_sequence: 3}} =
             DesktopMediaIngress.forward_frame(frame("desktop-ingress-mismatch-1", sequence: 3), session)
  end

  test "rejects frames above the session chunk limit" do
    session =
      "desktop-ingress-size-1"
      |> session()
      |> Map.put(:max_chunk_bytes, 2)

    assert {:error, :chunk_too_large} =
             DesktopMediaIngress.forward_frame(
               frame("desktop-ingress-size-1", payload: <<1, 2, 3>>),
               session
             )
  end

  defp session(desktop_session_id) do
    %{
      desktop_session_id: desktop_session_id,
      media_session_id: "media-#{desktop_session_id}",
      media_ingest_id: "ingest-#{desktop_session_id}",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      max_chunk_bytes: 1_048_576
    }
  end

  defp frame(desktop_session_id, opts) do
    %Desktopmedia.DesktopMediaFrameChunk{
      desktop_session_id: desktop_session_id,
      media_session_id: "media-#{desktop_session_id}",
      media_ingest_id: "ingest-#{desktop_session_id}",
      agent_id: "agent-1",
      sequence: Keyword.get(opts, :sequence, 1),
      metadata: Keyword.get(opts, :metadata, <<>>),
      payload: Keyword.get(opts, :payload, <<1, 2, 3>>)
    }
  end

  defp clear_ingress_sessions do
    if Process.whereis(DesktopMediaIngressSupervisor) do
      DesktopMediaIngressSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_id, pid, _type, _modules} when is_pid(pid) ->
          _ = DynamicSupervisor.terminate_child(DesktopMediaIngressSupervisor, pid)

        _other ->
          :ok
      end)
    end
  end

  defp reset_media_manager do
    if Process.whereis(MediaSessionManager), do: MediaSessionManager.reset()
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
