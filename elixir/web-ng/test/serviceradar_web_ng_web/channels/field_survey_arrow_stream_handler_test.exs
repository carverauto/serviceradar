defmodule ServiceRadarWebNGWeb.Channels.FieldSurveyArrowStreamHandlerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Channels.FieldSurveyArrowStreamHandler

  @payload <<1, 2, 3, 4>>

  test "routes RF Arrow frames through the RF decoder and bulk insert path" do
    parent = self()

    {:ok, state} =
      init_handler(
        session_id: "survey-rf",
        user_id: "user-1",
        stream_type: :rf_observations,
        decode_rf_payload: fn @payload ->
          {:ok, [%{bssid: "00:11:22:33:44:55"}, %{bssid: "66:77:88:99:aa:bb"}]}
        end,
        bulk_insert_rf: fn session_id, observations ->
          send(parent, {:rf_insert, session_id, observations})
          true
        end,
        archive_frame: fn payload, metadata ->
          send(parent, {:archive_frame, payload, metadata})
          true
        end
      )

    assert {:ok, state} = FieldSurveyArrowStreamHandler.handle_in({@payload, [opcode: :binary]}, state)
    assert state.message_count == 1
    assert state.bytes_received == byte_size(@payload)
    assert state.rows_received == 2
    assert state.frames_archived == 1
    assert_receive {:rf_insert, "survey-rf", [%{bssid: "00:11:22:33:44:55"}, %{bssid: "66:77:88:99:aa:bb"}]}

    assert_receive {:archive_frame, @payload,
                    %{
                      session_id: "survey-rf",
                      user_id: "user-1",
                      stream_type: :rf_observations,
                      frame_index: 1,
                      byte_size: 4,
                      row_count: 2,
                      decode_status: :ok,
                      decode_error: nil
                    }}
  end

  test "routes pose Arrow frames through the pose decoder and bulk insert path" do
    parent = self()

    {:ok, state} =
      init_handler(
        session_id: "survey-pose",
        user_id: "user-1",
        stream_type: :pose_samples,
        decode_pose_payload: fn @payload ->
          {:ok, [%{scanner_device_id: "iphone-1"}]}
        end,
        bulk_insert_pose: fn session_id, samples ->
          send(parent, {:pose_insert, session_id, samples})
          true
        end,
        archive_frame: fn _payload, metadata ->
          send(parent, {:archive_frame, metadata})
          true
        end
      )

    assert {:ok, state} = FieldSurveyArrowStreamHandler.handle_in({@payload, [opcode: :binary]}, state)
    assert state.rows_received == 1
    assert state.frames_archived == 1
    assert_receive {:pose_insert, "survey-pose", [%{scanner_device_id: "iphone-1"}]}
    assert_receive {:archive_frame, %{stream_type: :pose_samples, row_count: 1, decode_status: :ok}}
  end

  test "routes spectrum Arrow frames through the spectrum decoder and bulk insert path" do
    parent = self()

    {:ok, state} =
      init_handler(
        session_id: "survey-spectrum",
        user_id: "user-1",
        stream_type: :spectrum_observations,
        decode_spectrum_payload: fn @payload ->
          {:ok, [%{sdr_id: "hackrf-0"}, %{sdr_id: "hackrf-1"}, %{sdr_id: "hackrf-2"}]}
        end,
        bulk_insert_spectrum: fn session_id, observations ->
          send(parent, {:spectrum_insert, session_id, observations})
          true
        end,
        archive_frame: fn _payload, metadata ->
          send(parent, {:archive_frame, metadata})
          true
        end
      )

    assert {:ok, state} = FieldSurveyArrowStreamHandler.handle_in({@payload, [opcode: :binary]}, state)
    assert state.rows_received == 3
    assert state.frames_archived == 1

    assert_receive {:spectrum_insert, "survey-spectrum",
                    [%{sdr_id: "hackrf-0"}, %{sdr_id: "hackrf-1"}, %{sdr_id: "hackrf-2"}]}

    assert_receive {:archive_frame, %{stream_type: :spectrum_observations, row_count: 3, decode_status: :ok}}
  end

  test "archives failed frames and keeps stream open when decode fails" do
    parent = self()

    {:ok, state} =
      init_handler(
        session_id: "survey-bad",
        user_id: "user-1",
        stream_type: :rf_observations,
        decode_rf_payload: fn @payload -> {:error, :bad_arrow} end,
        bulk_insert_rf: fn _session_id, _observations -> flunk("bulk insert should not run") end,
        archive_frame: fn payload, metadata ->
          send(parent, {:archive_frame, payload, metadata})
          true
        end
      )

    assert {:ok, state} = FieldSurveyArrowStreamHandler.handle_in({@payload, [opcode: :binary]}, state)
    assert state.message_count == 1
    assert state.bytes_received == byte_size(@payload)
    assert state.rows_received == 0
    assert state.frames_archived == 1

    assert_receive {:archive_frame, @payload,
                    %{
                      session_id: "survey-bad",
                      stream_type: :rf_observations,
                      row_count: 0,
                      decode_status: :error,
                      decode_error: ":bad_arrow"
                    }}
  end

  test "ignores text frames" do
    {:ok, state} =
      init_handler(
        session_id: "survey-text",
        user_id: "user-1",
        stream_type: :rf_observations
      )

    assert {:ok, ^state} = FieldSurveyArrowStreamHandler.handle_in({"hello", [opcode: :text]}, state)
  end

  test "rejects oversized binary frames before decoding" do
    {:ok, state} =
      init_handler(
        session_id: "survey-large",
        user_id: "user-1",
        stream_type: :rf_observations
      )

    oversized_payload = :binary.copy(<<0>>, 8 * 1024 * 1024 + 1)

    assert {:stop, :normal, {1009, "FieldSurvey frame too large"}, ^state} =
             FieldSurveyArrowStreamHandler.handle_in({oversized_payload, [opcode: :binary]}, state)
  end

  test "rejects streams when the limiter denies the session" do
    assert {:stop, :normal, {1013, "too many FieldSurvey streams"}, _state} =
             init_handler(
               session_id: "survey-limited",
               user_id: "user-1",
               stream_type: :rf_observations,
               acquire_stream: fn _user_id, _session_id -> {:error, :too_many_user_streams} end
             )
  end

  defp init_handler(opts) do
    default_opts = [
      acquire_stream: fn _user_id, _session_id -> {:ok, nil} end,
      release_stream: fn _token -> :ok end
    ]

    FieldSurveyArrowStreamHandler.init(Keyword.merge(default_opts, opts))
  end
end
