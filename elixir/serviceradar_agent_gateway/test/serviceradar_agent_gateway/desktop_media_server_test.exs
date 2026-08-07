defmodule ServiceRadarAgentGateway.DesktopMediaServerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.DesktopMediaServer
  alias ServiceRadarAgentGateway.DesktopMediaSessionTracker
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub
  alias ServiceRadarAgentGateway.TestSupport.DesktopMediaFrameForwarderStub

  @moduletag :requires_app

  setup do
    previous_identity_resolver =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_identity_resolver)

    previous_frame_forwarder =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_frame_forwarder)

    previous_frame_forwarder_result =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_frame_forwarder_result)

    previous_frame_forwarder_close_result =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_frame_forwarder_close_result)

    previous_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_server_test_pid)

    previous_tracker =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_session_tracker_module)

    previous_state =
      DesktopMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

    :sys.replace_state(DesktopMediaSessionTracker, fn state ->
      Map.put(state, :sessions, %{})
    end)

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder,
      nil
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_identity_resolver,
      CameraMediaIdentityResolverStub
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_session_tracker_module,
      DesktopMediaSessionTracker
    )

    Application.put_env(:serviceradar_agent_gateway, :desktop_media_server_test_pid, self())

    on_exit(fn ->
      DesktopMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

      :sys.replace_state(DesktopMediaSessionTracker, fn _state -> previous_state end)

      restore_env(:desktop_media_identity_resolver, previous_identity_resolver)
      restore_env(:desktop_media_frame_forwarder, previous_frame_forwarder)
      restore_env(:desktop_media_frame_forwarder_result, previous_frame_forwarder_result)
      restore_env(:desktop_media_frame_forwarder_close_result, previous_frame_forwarder_close_result)
      restore_env(:desktop_media_server_test_pid, previous_test_pid)
      restore_env(:desktop_media_session_tracker_module, previous_tracker)
    end)

    :ok
  end

  test "opens, heartbeats, and closes a route-bound desktop media session" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder,
      DesktopMediaFrameForwarderStub
    )

    stream = test_stream()

    open_response =
      DesktopMediaServer.open_desktop_media_session(
        %Desktopmedia.OpenDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-1",
          media_session_id: "media-server-1",
          agent_id: "agent-1",
          target_id: "target-1",
          route_id: "route-1",
          lease_token: "lease-server-1",
          requested_initial_credit_bytes: 4096,
          requested_max_chunk_bytes: 1024,
          encoding_hint: "srdp-dirty-rect"
        },
        stream
      )

    assert open_response.accepted == true
    assert open_response.media_session_id == "media-server-1"
    assert open_response.media_ingest_id != ""
    assert open_response.initial_credit_bytes == 4096
    assert open_response.max_chunk_bytes == 1024
    assert open_response.max_ack_credit_bytes > 0

    heartbeat_response =
      DesktopMediaServer.heartbeat(
        %Desktopmedia.DesktopMediaHeartbeat{
          desktop_session_id: "desktop-server-1",
          media_session_id: "media-server-1",
          media_ingest_id: open_response.media_ingest_id,
          agent_id: "agent-1",
          last_sequence: 9,
          sent_bytes: 2048,
          received_credit_bytes: 1024,
          viewer_count: 1
        },
        stream
      )

    assert heartbeat_response.accepted == true
    assert heartbeat_response.lease_expires_at_unix > 0

    close_response =
      DesktopMediaServer.close_desktop_media_session(
        %Desktopmedia.CloseDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-1",
          media_session_id: "media-server-1",
          media_ingest_id: open_response.media_ingest_id,
          agent_id: "agent-1",
          reason: "test done"
        },
        stream
      )

    assert close_response.closed == true
    assert_receive {:close_desktop_media_ingress, "desktop-server-1"}
    assert DesktopMediaSessionTracker.fetch_session("desktop-server-1") == nil
  end

  test "close fails closed and retains route binding until core cleanup acknowledges" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder,
      DesktopMediaFrameForwarderStub
    )

    for {suffix, failure} <- [
          {"error", {:error, :core_unavailable}},
          {"raise", {:raise, "core unavailable"}},
          {"exit", {:exit, :core_unavailable}}
        ] do
      desktop_session_id = "desktop-close-fail-#{suffix}"
      media_session_id = "media-close-fail-#{suffix}"
      stream = test_stream()
      open_response = open_desktop_session!(desktop_session_id, media_session_id, stream)

      Application.put_env(
        :serviceradar_agent_gateway,
        :desktop_media_frame_forwarder_close_result,
        failure
      )

      error =
        assert_raise GRPC.RPCError, fn ->
          DesktopMediaServer.close_desktop_media_session(
            %Desktopmedia.CloseDesktopMediaSessionRequest{
              desktop_session_id: desktop_session_id,
              media_session_id: media_session_id,
              media_ingest_id: open_response.media_ingest_id,
              agent_id: "agent-1",
              reason: "browser closed"
            },
            stream
          )
        end

      assert error.status == GRPC.Status.unavailable()
      assert error.message =~ "temporarily unavailable"

      assert {:ok, retained} =
               DesktopMediaSessionTracker.fetch_session(desktop_session_id, "agent-1")

      assert retained.status == "closing"
      assert retained.pending_core_cleanup == true
      expire_desktop_session!(desktop_session_id)
      assert {:ok, 0} = DesktopMediaSessionTracker.sweep_expired_sessions()
      assert {:ok, _retained} = DesktopMediaSessionTracker.fetch_session(desktop_session_id, "agent-1")

      Application.put_env(
        :serviceradar_agent_gateway,
        :desktop_media_frame_forwarder_close_result,
        :ok
      )

      retry_response =
        DesktopMediaServer.close_desktop_media_session(
          %Desktopmedia.CloseDesktopMediaSessionRequest{
            desktop_session_id: desktop_session_id,
            media_session_id: media_session_id,
            media_ingest_id: open_response.media_ingest_id,
            agent_id: "agent-1",
            reason: "browser closed"
          },
          stream
        )

      assert retry_response.closed == true
      assert DesktopMediaSessionTracker.fetch_session(desktop_session_id) == nil
    end
  end

  test "close fails closed when the core cleanup forwarder is not configured" do
    stream = test_stream()

    open_response =
      open_desktop_session!("desktop-close-no-forwarder", "media-close-no-forwarder", stream)

    error =
      assert_raise GRPC.RPCError, fn ->
        DesktopMediaServer.close_desktop_media_session(
          %Desktopmedia.CloseDesktopMediaSessionRequest{
            desktop_session_id: "desktop-close-no-forwarder",
            media_session_id: "media-close-no-forwarder",
            media_ingest_id: open_response.media_ingest_id,
            agent_id: "agent-1",
            reason: "browser closed"
          },
          stream
        )
      end

    assert error.status == GRPC.Status.unavailable()

    assert {:ok, retained} =
             DesktopMediaSessionTracker.fetch_session("desktop-close-no-forwarder", "agent-1")

    assert retained.status == "closing"
    assert retained.pending_core_cleanup == true
  end

  test "rejects desktop media open when certificate identity does not match requested agent" do
    assert_raise GRPC.RPCError, ~r/component identity mismatch/, fn ->
      DesktopMediaServer.open_desktop_media_session(
        %Desktopmedia.OpenDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-mismatch-1",
          media_session_id: "media-server-mismatch-1",
          agent_id: "agent-other",
          target_id: "target-1",
          route_id: "route-1",
          lease_token: "lease-server-mismatch-1"
        },
        test_stream()
      )
    end
  end

  test "rejects heartbeat for the wrong media session binding" do
    stream = test_stream()

    open_response =
      DesktopMediaServer.open_desktop_media_session(
        %Desktopmedia.OpenDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-media-mismatch-1",
          media_session_id: "media-server-owner-1",
          agent_id: "agent-1",
          target_id: "target-1",
          route_id: "route-1",
          lease_token: "lease-server-media-mismatch-1"
        },
        stream
      )

    assert open_response.accepted == true

    assert_raise GRPC.RPCError, ~r/media_session_id mismatch/, fn ->
      DesktopMediaServer.heartbeat(
        %Desktopmedia.DesktopMediaHeartbeat{
          desktop_session_id: "desktop-server-media-mismatch-1",
          media_session_id: "media-other",
          agent_id: "agent-1"
        },
        stream
      )
    end
  end

  test "rejects desktop media control calls with the wrong media ingest binding" do
    stream = test_stream()

    open_response =
      DesktopMediaServer.open_desktop_media_session(
        %Desktopmedia.OpenDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-ingest-mismatch-1",
          media_session_id: "media-server-ingest-mismatch-1",
          agent_id: "agent-1",
          target_id: "target-1",
          route_id: "route-1",
          lease_token: "lease-server-ingest-mismatch-1"
        },
        stream
      )

    assert open_response.accepted == true

    assert_raise GRPC.RPCError, ~r/media_ingest_id mismatch/, fn ->
      DesktopMediaServer.heartbeat(
        %Desktopmedia.DesktopMediaHeartbeat{
          desktop_session_id: "desktop-server-ingest-mismatch-1",
          media_session_id: "media-server-ingest-mismatch-1",
          media_ingest_id: "media-ingest-other",
          agent_id: "agent-1"
        },
        stream
      )
    end

    assert_raise GRPC.RPCError, ~r/media_ingest_id mismatch/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:close,
               %Desktopmedia.DesktopMediaStreamClose{
                 desktop_session_id: "desktop-server-ingest-mismatch-1",
                 media_session_id: "media-server-ingest-mismatch-1",
                 media_ingest_id: "media-ingest-other",
                 agent_id: "agent-1"
               }}
          }
        ],
        stream
      )
    end

    assert_raise GRPC.RPCError, ~r/media_ingest_id mismatch/, fn ->
      DesktopMediaServer.close_desktop_media_session(
        %Desktopmedia.CloseDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-ingest-mismatch-1",
          media_session_id: "media-server-ingest-mismatch-1",
          media_ingest_id: "media-ingest-other",
          agent_id: "agent-1"
        },
        stream
      )
    end

    assert {:ok, session} =
             DesktopMediaSessionTracker.fetch_session(
               "desktop-server-ingest-mismatch-1",
               "agent-1"
             )

    assert session.media_ingest_id == open_response.media_ingest_id
  end

  test "fails closed when desktop media stream forwarding is not enabled" do
    assert_raise GRPC.RPCError, ~r/desktop media frame forwarding is not enabled/, fn ->
      stream = test_stream()
      open_desktop_session!("desktop-stream-frame-1", "media-stream-frame-1", stream)

      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-frame-1",
                 media_session_id: "media-stream-frame-1",
                 agent_id: "agent-1",
                 sequence: 1,
                 payload: <<1, 2, 3>>
               }}
          }
        ],
        stream
      )
    end
  end

  test "desktop media stream forwards frames through configured forwarder and applies ack credit" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder,
      DesktopMediaFrameForwarderStub
    )

    stream = test_stream(test_pid: self())
    open_response = open_desktop_session!("desktop-stream-forward-1", "media-stream-forward-1", stream)

    assert :ok =
             DesktopMediaServer.stream_desktop_media(
               [
                 %Desktopmedia.DesktopMediaClientMessage{
                   message:
                     {:frame,
                      %Desktopmedia.DesktopMediaFrameChunk{
                        desktop_session_id: "desktop-stream-forward-1",
                        media_session_id: "media-stream-forward-1",
                        media_ingest_id: open_response.media_ingest_id,
                        agent_id: "agent-1",
                        sequence: 11,
                        payload: <<1, 2, 3>>
                      }}
                 }
               ],
               stream
             )

    assert_receive {:forward_desktop_media_frame,
                    %Desktopmedia.DesktopMediaFrameChunk{
                      desktop_session_id: "desktop-stream-forward-1",
                      media_session_id: "media-stream-forward-1",
                      sequence: 11,
                      payload: <<1, 2, 3>>
                    }, %{desktop_session_id: "desktop-stream-forward-1", media_session_id: "media-stream-forward-1"}}

    assert_receive {:desktop_media_stream_reply,
                    %Desktopmedia.DesktopMediaServerMessage{
                      message:
                        {:ack,
                         %Desktopmedia.DesktopMediaAck{
                           desktop_session_id: "desktop-stream-forward-1",
                           media_session_id: "media-stream-forward-1",
                           media_ingest_id: media_ingest_id,
                           last_accepted_sequence: 11,
                           credit_bytes: 3
                         }}
                    }}

    assert media_ingest_id == open_response.media_ingest_id

    assert {:ok, session} =
             DesktopMediaSessionTracker.fetch_session("desktop-stream-forward-1", "agent-1")

    assert session.last_sequence == 11
    assert session.sent_bytes == 3
    assert session.last_accepted_sequence == 11
    assert session.received_credit_bytes == 3
  end

  test "desktop media stream does not mutate counters when configured forwarder fails" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder,
      DesktopMediaFrameForwarderStub
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder_result,
      {:error, :downstream_unavailable}
    )

    stream = test_stream()
    open_desktop_session!("desktop-stream-forward-fail-1", "media-stream-forward-fail-1", stream)

    assert_raise GRPC.RPCError, ~r/desktop media frame forward failed/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-forward-fail-1",
                 media_session_id: "media-stream-forward-fail-1",
                 agent_id: "agent-1",
                 sequence: 7,
                 payload: <<1, 2, 3>>
               }}
          }
        ],
        stream
      )
    end

    assert {:ok, session} =
             DesktopMediaSessionTracker.fetch_session("desktop-stream-forward-fail-1", "agent-1")

    assert session.last_sequence == 0
    assert session.sent_bytes == 0
    assert session.last_accepted_sequence == 0
    assert session.received_credit_bytes == 0
  end

  test "desktop media stream rejects mismatched downstream acknowledgements before mutating counters" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder,
      DesktopMediaFrameForwarderStub
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder_result,
      {:ok,
       %Desktopmedia.DesktopMediaAck{
         desktop_session_id: "desktop-other",
         media_session_id: "media-stream-ack-mismatch-1",
         last_accepted_sequence: 7,
         credit_bytes: 3
       }}
    )

    stream = test_stream()
    open_desktop_session!("desktop-stream-ack-mismatch-1", "media-stream-ack-mismatch-1", stream)

    assert_raise GRPC.RPCError, ~r/desktop_session_id mismatch/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-ack-mismatch-1",
                 media_session_id: "media-stream-ack-mismatch-1",
                 agent_id: "agent-1",
                 sequence: 7,
                 payload: <<1, 2, 3>>
               }}
          }
        ],
        stream
      )
    end

    assert {:ok, session} =
             DesktopMediaSessionTracker.fetch_session("desktop-stream-ack-mismatch-1", "agent-1")

    assert session.last_sequence == 0
    assert session.sent_bytes == 0
    assert session.last_accepted_sequence == 0
    assert session.received_credit_bytes == 0
  end

  test "desktop media stream accepts heartbeat and close control messages" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder,
      DesktopMediaFrameForwarderStub
    )

    stream = test_stream(test_pid: self())
    open_response = open_desktop_session!("desktop-stream-control-1", "media-stream-control-1", stream)

    assert :ok =
             DesktopMediaServer.stream_desktop_media(
               [
                 %Desktopmedia.DesktopMediaClientMessage{
                   message:
                     {:heartbeat,
                      %Desktopmedia.DesktopMediaHeartbeat{
                        desktop_session_id: "desktop-stream-control-1",
                        media_session_id: "media-stream-control-1",
                        media_ingest_id: open_response.media_ingest_id,
                        agent_id: "agent-1",
                        last_sequence: 3,
                        sent_bytes: 512,
                        received_credit_bytes: 256,
                        viewer_count: 1
                      }}
                 },
                 %Desktopmedia.DesktopMediaClientMessage{
                   message:
                     {:close,
                      %Desktopmedia.DesktopMediaStreamClose{
                        desktop_session_id: "desktop-stream-control-1",
                        media_session_id: "media-stream-control-1",
                        media_ingest_id: open_response.media_ingest_id,
                        agent_id: "agent-1",
                        reason: "done",
                        last_sequence: 3
                      }}
                 }
               ],
               stream
             )

    assert_receive {:desktop_media_stream_reply,
                    %Desktopmedia.DesktopMediaServerMessage{
                      message:
                        {:heartbeat,
                         %Desktopmedia.DesktopMediaHeartbeatAck{
                           accepted: true,
                           message: "desktop media heartbeat accepted"
                         }}
                    }}

    assert_receive {:desktop_media_stream_reply,
                    %Desktopmedia.DesktopMediaServerMessage{
                      message:
                        {:close,
                         %Desktopmedia.DesktopMediaStreamClose{
                           desktop_session_id: "desktop-stream-control-1",
                           media_session_id: "media-stream-control-1",
                           agent_id: "agent-1",
                           reason: "done",
                           last_sequence: 3
                         }}
                    }}

    assert DesktopMediaSessionTracker.fetch_session("desktop-stream-control-1") == nil
    assert_receive {:close_desktop_media_ingress, "desktop-stream-control-1"}
  end

  test "desktop media stream validates frame media binding before forwarding gate" do
    stream = test_stream()
    open_response = open_desktop_session!("desktop-stream-media-mismatch-1", "media-stream-owner-1", stream)

    assert_raise GRPC.RPCError, ~r/media_session_id mismatch/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-media-mismatch-1",
                 media_session_id: "media-other",
                 agent_id: "agent-1",
                 sequence: 1,
                 payload: <<1>>
               }}
          }
        ],
        stream
      )
    end

    assert_raise GRPC.RPCError, ~r/media_ingest_id mismatch/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-media-mismatch-1",
                 media_session_id: "media-stream-owner-1",
                 media_ingest_id: "media-ingest-other",
                 agent_id: "agent-1",
                 sequence: 1,
                 payload: <<1>>
               }}
          }
        ],
        stream
      )
    end

    assert {:ok, session} =
             DesktopMediaSessionTracker.fetch_session("desktop-stream-media-mismatch-1", "agent-1")

    assert session.media_ingest_id == open_response.media_ingest_id
    assert session.last_sequence == 0
    assert session.sent_bytes == 0
  end

  test "desktop media stream rejects frames when certificate partition does not match the session" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder,
      DesktopMediaFrameForwarderStub
    )

    stream = test_stream(test_pid: self())
    open_response = open_desktop_session!("desktop-stream-partition-mismatch-1", "media-stream-partition-1", stream)

    handler_id = {__MODULE__, self(), :desktop_media_frame_rejected}

    :telemetry.attach(
      handler_id,
      [:serviceradar, :desktop_media, :frame, :rejected],
      fn event, measurements, metadata, _config ->
        send(self(), {:desktop_media_frame_rejected, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    rewrite_desktop_session!("desktop-stream-partition-mismatch-1", fn session ->
      %{session | partition_id: "other-partition"}
    end)

    assert_raise GRPC.RPCError, ~r/desktop media session partition mismatch/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-partition-mismatch-1",
                 media_session_id: "media-stream-partition-1",
                 media_ingest_id: open_response.media_ingest_id,
                 agent_id: "agent-1",
                 sequence: 1,
                 payload: <<1>>
               }}
          }
        ],
        stream
      )
    end

    assert_receive {:desktop_media_frame_rejected, [:serviceradar, :desktop_media, :frame, :rejected],
                    %{payload_bytes: 1, sequence: 1},
                    %{
                      agent_id: "agent-1",
                      certificate_partition_id: "default",
                      desktop_session_id: "desktop-stream-partition-mismatch-1",
                      reason: :partition_id_mismatch,
                      session_partition_id: "other-partition"
                    }}

    refute_receive {:forward_desktop_media_frame, _frame, _session}

    assert {:ok, session} =
             DesktopMediaSessionTracker.fetch_session("desktop-stream-partition-mismatch-1", "agent-1")

    assert session.last_sequence == 0
    assert session.sent_bytes == 0
  end

  test "desktop media stream rejects frames after the session starts closing" do
    stream = test_stream()
    open_response = open_desktop_session!("desktop-stream-closing-1", "media-stream-closing-1", stream)

    assert {:ok, closing} =
             DesktopMediaSessionTracker.mark_closing(
               "desktop-stream-closing-1",
               "media-stream-closing-1",
               "agent-1",
               %{media_ingest_id: open_response.media_ingest_id, reason: "browser closed"}
             )

    assert closing.status == "closing"

    assert_raise GRPC.RPCError, ~r/desktop media session is closing/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-closing-1",
                 media_session_id: "media-stream-closing-1",
                 media_ingest_id: open_response.media_ingest_id,
                 agent_id: "agent-1",
                 sequence: 1,
                 payload: <<1>>
               }}
          }
        ],
        stream
      )
    end
  end

  test "desktop media stream rejects frames after session lease expiry" do
    stream = test_stream()
    open_response = open_desktop_session!("desktop-stream-expired-1", "media-stream-expired-1", stream)

    expire_desktop_session!("desktop-stream-expired-1")

    assert_raise GRPC.RPCError, ~r/desktop media session expired/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-expired-1",
                 media_session_id: "media-stream-expired-1",
                 media_ingest_id: open_response.media_ingest_id,
                 agent_id: "agent-1",
                 sequence: 1,
                 payload: <<1>>
               }}
          }
        ],
        stream
      )
    end
  end

  test "desktop media stream rejects frames above the session chunk limit" do
    stream = test_stream()

    DesktopMediaServer.open_desktop_media_session(
      %Desktopmedia.OpenDesktopMediaSessionRequest{
        desktop_session_id: "desktop-stream-size-1",
        media_session_id: "media-stream-size-1",
        agent_id: "agent-1",
        target_id: "target-1",
        route_id: "route-1",
        lease_token: "lease-stream-size-1",
        requested_max_chunk_bytes: 2
      },
      stream
    )

    assert_raise GRPC.RPCError, ~r/desktop media frame exceeded max size 2/, fn ->
      DesktopMediaServer.stream_desktop_media(
        [
          %Desktopmedia.DesktopMediaClientMessage{
            message:
              {:frame,
               %Desktopmedia.DesktopMediaFrameChunk{
                 desktop_session_id: "desktop-stream-size-1",
                 media_session_id: "media-stream-size-1",
                 agent_id: "agent-1",
                 sequence: 1,
                 payload: <<1, 2, 3>>
               }}
          }
        ],
        stream
      )
    end
  end

  defp open_desktop_session!(desktop_session_id, media_session_id, stream) do
    DesktopMediaServer.open_desktop_media_session(
      %Desktopmedia.OpenDesktopMediaSessionRequest{
        desktop_session_id: desktop_session_id,
        media_session_id: media_session_id,
        agent_id: "agent-1",
        target_id: "target-1",
        route_id: "route-1",
        lease_token: "lease-#{desktop_session_id}"
      },
      stream
    )
  end

  defp expire_desktop_session!(desktop_session_id) do
    expired_at = System.os_time(:second) - 60

    rewrite_desktop_session!(desktop_session_id, fn session ->
      %{session | lease_expires_at_unix: expired_at}
    end)
  end

  defp rewrite_desktop_session!(desktop_session_id, rewrite_fun) when is_function(rewrite_fun, 1) do
    :sys.replace_state(DesktopMediaSessionTracker, fn state ->
      update_in(state, [:sessions, desktop_session_id], rewrite_fun)
    end)
  end

  defp test_stream(opts) do
    Map.merge(test_stream(), Map.new(opts))
  end

  defp test_stream do
    %{adapter: CameraMediaAdapterStub, payload: :test}
  end

  defp clear_sessions(state) do
    Map.put(state, :sessions, %{})
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
