defmodule ServiceRadarCoreElx.DesktopMediaIngressTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.DesktopMediaIngress
  alias ServiceRadarCoreElx.DesktopMediaIngressSupervisor

  setup do
    clear_ingress_sessions()

    on_exit(fn ->
      clear_ingress_sessions()
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
              credit_bytes: 4
            }} =
             DesktopMediaIngress.forward_frame(frame("desktop-ingress-1", sequence: 9, payload: <<1, 2, 3, 4>>), session)

    assert [{_, ingress_pid, _, _}] = DynamicSupervisor.which_children(DesktopMediaIngressSupervisor)
    assert is_pid(ingress_pid)

    assert {:ok, %Desktopmedia.DesktopMediaAck{last_accepted_sequence: 10, credit_bytes: 3}} =
             DesktopMediaIngress.forward_frame(frame("desktop-ingress-1", sequence: 10), session)

    assert [{_, ^ingress_pid, _, _}] = DynamicSupervisor.which_children(DesktopMediaIngressSupervisor)
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
end
