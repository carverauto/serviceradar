defmodule ServiceRadarCoreElx.CameraMediaIngressTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraMediaIngress
  alias ServiceRadarCoreElx.CameraMediaIngressSession
  alias ServiceRadarCoreElx.CameraMediaIngressSupervisor
  alias ServiceRadarCoreElx.CameraMediaSessionTracker

  defmodule RelaySessionLifecycleStub do
    @moduledoc false

    def activate_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:activate_session, relay_session_id, media_ingest_id, attrs})
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id}}
    end

    def heartbeat_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:heartbeat_session, relay_session_id, media_ingest_id, attrs})
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id}}
    end

    def close_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:close_session, relay_session_id, media_ingest_id, attrs})
      {:ok, %{id: relay_session_id, media_ingest_id: media_ingest_id, close_reason: attrs[:close_reason]}}
    end

    def fail_session(relay_session_id, media_ingest_id, attrs, opts) do
      send(opts[:test_pid], {:fail_session, relay_session_id, media_ingest_id, attrs})

      {:ok,
       %{
         id: relay_session_id,
         media_ingest_id: media_ingest_id,
         close_reason: attrs[:close_reason],
         failure_reason: attrs[:failure_reason]
       }}
    end
  end

  setup do
    clear_ingress_sessions()

    previous_state =
      CameraMediaSessionTracker
      |> :sys.get_state()
      |> Map.put(:sessions, %{})

    test_pid = self()

    :sys.replace_state(CameraMediaSessionTracker, fn state ->
      state
      |> Map.put(:sessions, %{})
      |> Map.put(:sync_module, RelaySessionLifecycleStub)
      |> Map.put(:sync_opts, test_pid: test_pid)
    end)

    on_exit(fn ->
      clear_ingress_sessions()

      :sys.replace_state(CameraMediaSessionTracker, fn _state ->
        previous_state
      end)
    end)

    :ok
  end

  # credo:disable-for-next-line Jump.CredoChecks.TooManyAssertions
  test "opens an ingress pid and forwards upload, heartbeat, and close through it" do
    relay_session_id = unique_id("relay-ingress")
    :ok = RelayPubSub.subscribe(relay_session_id)

    {:ok, open_response, %{ingress_pid: ingress_pid, core_node: core_node}} =
      CameraMediaIngress.open_relay_session(
        %Camera.OpenRelaySessionRequest{
          relay_session_id: relay_session_id,
          agent_id: "agent-1",
          gateway_id: "gateway-1",
          camera_source_id: "camera-1",
          stream_profile_id: "main",
          codec_hint: "h264",
          container_hint: "annexb",
          source_incarnation_id: "b0ede4c7-23ca-412f-91ad-77ce4ae8e33c"
        },
        close_grace_ms: 50
      )

    assert open_response.accepted == true
    assert open_response.message == "core relay session accepted"
    assert is_pid(ingress_pid)
    assert core_node == node()

    assert_receive {:activate_session, ^relay_session_id, media_ingest_id,
                    %{
                      viewer_count: 0,
                      agent_id: "agent-1",
                      gateway_id: "gateway-1",
                      camera_source_id: "camera-1",
                      stream_profile_id: "main",
                      source_incarnation_id: "b0ede4c7-23ca-412f-91ad-77ce4ae8e33c"
                    }}

    assert open_response.media_ingest_id == media_ingest_id

    assert %{
             relay_session_id: ^relay_session_id,
             media_ingest_id: ^media_ingest_id
           } = CameraMediaSessionTracker.fetch_session(relay_session_id)

    upload_response =
      CameraMediaIngressSession.upload_media(ingress_pid, [
        %Camera.MediaChunk{
          relay_session_id: relay_session_id,
          media_ingest_id: media_ingest_id,
          sequence: 7,
          payload: <<1, 2, 3, 4>>,
          codec: "h264",
          payload_format: "annexb",
          track_id: "video"
        }
      ])

    assert {:ok, %Camera.UploadMediaResponse{} = upload_ack} = upload_response
    assert upload_ack.received == true
    assert upload_ack.last_sequence == 7
    assert upload_ack.message == "media chunks accepted by core-elx"

    heartbeat_response =
      CameraMediaIngressSession.heartbeat(
        ingress_pid,
        %Camera.RelayHeartbeat{
          relay_session_id: relay_session_id,
          media_ingest_id: media_ingest_id,
          last_sequence: 7,
          sent_bytes: 4
        }
      )

    assert {:ok, %Camera.RelayHeartbeatAck{} = heartbeat_ack} = heartbeat_response
    assert heartbeat_ack.accepted == true
    assert heartbeat_ack.message == "core heartbeat accepted"

    assert_receive {:heartbeat_session, ^relay_session_id, ^media_ingest_id, %{renew_ingest?: true, viewer_count: 0}}

    assert {:ok, %Camera.CloseRelaySessionResponse{} = close_response} =
             CameraMediaIngressSession.close_relay_session(
               ingress_pid,
               %Camera.CloseRelaySessionRequest{
                 relay_session_id: relay_session_id,
                 media_ingest_id: media_ingest_id,
                 reason: "operator stop"
               }
             )

    assert close_response.closed == true
    assert close_response.message == "core relay session closed"

    assert_receive {:close_session, ^relay_session_id, ^media_ingest_id,
                    %{close_reason: "operator stop", viewer_count: 0}}

    assert CameraMediaSessionTracker.fetch_session(relay_session_id) == nil

    # An upload queued behind the close (a separate gateway handler) gets a
    # drain answer instead of the caller exiting {:normal, {GenServer, :call, _}}.
    ingress_ref = Process.monitor(ingress_pid)

    assert {:ok, %Camera.UploadMediaResponse{received: false, message: late_message}} =
             CameraMediaIngressSession.upload_media(ingress_pid, [
               %Camera.MediaChunk{relay_session_id: relay_session_id, media_ingest_id: media_ingest_id, sequence: 8}
             ])

    assert late_message =~ "drain"
    assert_receive {:DOWN, ^ingress_ref, :process, ^ingress_pid, :normal}, 1_000
  end

  test "accepts a legacy gateway request without a runtime identity field" do
    relay_session_id = unique_id("relay-legacy-gateway")

    request =
      Map.delete(
        %Camera.OpenRelaySessionRequest{
          relay_session_id: relay_session_id,
          agent_id: "agent-1",
          gateway_id: "gateway-1",
          camera_source_id: "camera-1",
          stream_profile_id: "main"
        },
        :source_incarnation_id
      )

    assert {:ok, %{accepted: true}, %{ingress_pid: ingress_pid}} =
             CameraMediaIngress.open_relay_session(request)

    assert_receive {:activate_session, ^relay_session_id, _, %{source_incarnation_id: nil}}
    assert Process.alive?(ingress_pid)
  end

  test "returns drain acknowledgments when the relay is already closing" do
    relay_session_id = unique_id("relay-ingress-drain")
    :ok = RelayPubSub.subscribe(relay_session_id)

    {:ok, open_response, %{ingress_pid: ingress_pid}} =
      CameraMediaIngress.open_relay_session(%Camera.OpenRelaySessionRequest{
        relay_session_id: relay_session_id,
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        camera_source_id: "camera-1",
        stream_profile_id: "main"
      })

    media_ingest_id = open_response.media_ingest_id

    :ok =
      CameraMediaSessionTracker.mark_closing(relay_session_id, %{
        close_reason: "viewer idle timeout",
        viewer_count: 0
      })

    assert_receive {:camera_relay_state, %{relay_session_id: ^relay_session_id, status: "closing"}}

    assert {:ok, %Camera.UploadMediaResponse{} = upload_ack} =
             CameraMediaIngressSession.upload_media(ingress_pid, [
               %Camera.MediaChunk{
                 relay_session_id: relay_session_id,
                 media_ingest_id: media_ingest_id,
                 sequence: 9,
                 payload: <<9, 8, 7>>,
                 codec: "h264",
                 payload_format: "annexb"
               }
             ])

    assert upload_ack.message == "media chunks accepted during relay drain"

    assert {:ok, %Camera.RelayHeartbeatAck{} = heartbeat_ack} =
             CameraMediaIngressSession.heartbeat(
               ingress_pid,
               %Camera.RelayHeartbeat{
                 relay_session_id: relay_session_id,
                 media_ingest_id: media_ingest_id,
                 last_sequence: 9,
                 sent_bytes: 3
               }
             )

    assert heartbeat_ack.message == "core heartbeat accepted during relay drain"
  end

  test "stores the agent's source failure reason only after validating and sanitizing it" do
    # Invented credentials. The agent strips them; core must not trust that it did.
    leaky_url = "rtsps://viewer:hunter2@camera01.example.com:7441/AbCdEf0123TokenXyz?enableSrtp"
    long_detail = String.duplicate("timeout ", 40)

    cases = [
      {"authentication_failed: describe rtsp stream: bad status code: 401 (Unauthorized)",
       {:failed, "authentication_failed: describe rtsp stream: bad status code: 401 (Unauthorized)"}},
      {"unknown: describe #{leaky_url} failed\0\r\n",
       {:failed, "unknown: describe rtsps://camera01.example.com:7441 failed"}},
      {"read_timeout_no_media: " <> long_detail,
       {:failed, "read_timeout_no_media: " <> String.trim(String.duplicate("timeout ", 25))}},
      {"Authentication Failed: 401", :closed},
      {"auth\0failed: 401", :closed},
      {"unknown: " <> String.duplicate("x", 600), :closed},
      {"", :closed}
    ]

    for {reported, expected} <- cases do
      relay_session_id = unique_id("relay-source-failure")
      :ok = RelayPubSub.subscribe(relay_session_id)

      {:ok, %{media_ingest_id: media_ingest_id}, %{ingress_pid: ingress_pid}} =
        CameraMediaIngress.open_relay_session(%Camera.OpenRelaySessionRequest{
          relay_session_id: relay_session_id,
          agent_id: "agent-1",
          gateway_id: "gateway-1",
          camera_source_id: "camera-1",
          stream_profile_id: "main"
        })

      {result, log} =
        ExUnit.CaptureLog.with_log([level: :warning], fn ->
          CameraMediaIngressSession.close_relay_session(ingress_pid, %Camera.CloseRelaySessionRequest{
            relay_session_id: relay_session_id,
            media_ingest_id: media_ingest_id,
            agent_id: "agent-1",
            reason: "source_start_failed",
            failure_reason: reported
          })
        end)

      assert {:ok, %Camera.CloseRelaySessionResponse{closed: true}} = result
      refute log =~ "hunter2"

      case expected do
        {:failed, stored} ->
          assert_receive {:fail_session, ^relay_session_id, ^media_ingest_id,
                          %{close_reason: "source_start_failed", failure_reason: ^stored, viewer_count: 0}}

          assert_receive {:camera_relay_state,
                          %{
                            relay_session_id: ^relay_session_id,
                            status: "failed",
                            termination_kind: "failure",
                            failure_reason: ^stored
                          }}

          assert log =~ "Core camera relay source failed"
          assert log =~ "failure_reason=#{stored}"

        :closed ->
          assert_receive {:close_session, ^relay_session_id, ^media_ingest_id, %{close_reason: "source_start_failed"}}
          refute_received {:fail_session, ^relay_session_id, _media_ingest_id, _attrs}
          refute log =~ "Core camera relay source failed"
      end
    end
  end

  defmodule ExitingTrackerStub do
    @moduledoc false

    def heartbeat(_relay_session_id, _media_ingest_id, %{last_sequence: 101}) do
      exit({:timeout, {GenServer, :call, [CameraMediaSessionTracker, :heartbeat, 5_000]}})
    end

    def heartbeat(_relay_session_id, _media_ingest_id, %{last_sequence: 102}) do
      exit(:noproc)
    end

    def heartbeat(relay_session_id, media_ingest_id, _attrs) do
      {:ok,
       %{
         relay_session_id: relay_session_id,
         media_ingest_id: media_ingest_id,
         status: "active",
         lease_expires_at_unix: 2_000_000_030
       }}
    end

    def record_chunk(_relay_session_id, _media_ingest_id, %{sequence: 201}) do
      exit({:timeout, {GenServer, :call, [CameraMediaSessionTracker, :record_chunk, 5_000]}})
    end

    def record_chunk(relay_session_id, media_ingest_id, _attrs) do
      {:ok,
       %{
         relay_session_id: relay_session_id,
         media_ingest_id: media_ingest_id,
         status: "active",
         lease_expires_at_unix: 2_000_000_030
       }}
    end
  end

  test "survives transient tracker timeout and noproc exits on heartbeat" do
    relay_session_id = unique_id("relay-tracker-timeout")
    media_ingest_id = "core-media-timeout-test"

    session = %{
      relay_session_id: relay_session_id,
      media_ingest_id: media_ingest_id,
      status: "active",
      lease_expires_at_unix: 2_000_000_000
    }

    {:ok, ingress_pid} =
      CameraMediaIngressSupervisor.start_session(session, tracker: ExitingTrackerStub, close_grace_ms: 50)

    {timeout_result, timeout_log} =
      ExUnit.CaptureLog.with_log([level: :warning], fn ->
        CameraMediaIngressSession.heartbeat(ingress_pid, %Camera.RelayHeartbeat{
          relay_session_id: relay_session_id,
          media_ingest_id: media_ingest_id,
          last_sequence: 101,
          sent_bytes: 1024
        })
      end)

    assert {:ok, %Camera.RelayHeartbeatAck{accepted: true, lease_expires_at_unix: 2_000_000_000}} = timeout_result
    assert Process.alive?(ingress_pid)
    assert timeout_log =~ "tracker_heartbeat_timeout"

    {noproc_result, noproc_log} =
      ExUnit.CaptureLog.with_log([level: :warning], fn ->
        CameraMediaIngressSession.heartbeat(ingress_pid, %Camera.RelayHeartbeat{
          relay_session_id: relay_session_id,
          media_ingest_id: media_ingest_id,
          last_sequence: 102,
          sent_bytes: 2048
        })
      end)

    assert {:ok, %Camera.RelayHeartbeatAck{accepted: true, lease_expires_at_unix: 2_000_000_000}} = noproc_result
    assert noproc_log =~ "tracker_heartbeat_noproc"

    # Session remains healthy for subsequent heartbeats once tracker recovers.
    assert {:ok, %Camera.RelayHeartbeatAck{accepted: true, lease_expires_at_unix: 2_000_000_030}} =
             CameraMediaIngressSession.heartbeat(ingress_pid, %Camera.RelayHeartbeat{
               relay_session_id: relay_session_id,
               media_ingest_id: media_ingest_id,
               last_sequence: 103,
               sent_bytes: 4096
             })
  end

  test "survives transient tracker timeout exit on record_chunk without crashing session" do
    relay_session_id = unique_id("relay-chunk-timeout")
    media_ingest_id = "core-media-chunk-timeout-test"

    session = %{
      relay_session_id: relay_session_id,
      media_ingest_id: media_ingest_id,
      status: "active",
      lease_expires_at_unix: 2_000_000_000
    }

    {:ok, ingress_pid} =
      CameraMediaIngressSupervisor.start_session(session, tracker: ExitingTrackerStub, close_grace_ms: 50)

    {chunk_result, chunk_log} =
      ExUnit.CaptureLog.with_log([level: :warning], fn ->
        CameraMediaIngressSession.upload_media(ingress_pid, [
          %Camera.MediaChunk{
            relay_session_id: relay_session_id,
            media_ingest_id: media_ingest_id,
            sequence: 200,
            payload: <<1, 2, 3>>
          },
          %Camera.MediaChunk{
            relay_session_id: relay_session_id,
            media_ingest_id: media_ingest_id,
            sequence: 201,
            payload: <<4, 5, 6>>
          }
        ])
      end)

    assert {:ok, %Camera.UploadMediaResponse{received: true, last_sequence: 200}} = chunk_result
    assert Process.alive?(ingress_pid)
    assert chunk_log =~ "tracker_record_chunk_timeout"
  end

  defp clear_ingress_sessions do
    if Process.whereis(CameraMediaIngressSupervisor) do
      CameraMediaIngressSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_id, pid, _type, _modules} when is_pid(pid) ->
          _ = DynamicSupervisor.terminate_child(CameraMediaIngressSupervisor, pid)

        _other ->
          :ok
      end)
    end
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
