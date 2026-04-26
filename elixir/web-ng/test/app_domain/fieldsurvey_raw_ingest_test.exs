defmodule ServiceRadarWebNG.FieldSurveyRawIngestTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Spatial.SurveyPoseSample
  alias ServiceRadar.Spatial.SurveyRfObservation
  alias ServiceRadar.Spatial.SurveySpectrumObservation

  test "bulk raw ingest persists RF, pose, and spectrum rows and exposes nearest pose matches" do
    session_id = "fieldsurvey-test-#{System.unique_integer([:positive])}"
    rf_unix_nanos = 1_800_000_000_050_000_000
    pose_unix_nanos = rf_unix_nanos + 75_000_000

    assert true =
             SurveyRfObservation
             |> Ash.ActionInput.for_action(:bulk_insert, %{
               session_id: session_id,
               observations: [
                 %{
                   sidekick_id: "sidekick-rpi-1",
                   radio_id: "usb3-mt7612u",
                   interface_name: "wlan2mon",
                   bssid: "02:11:22:33:44:55",
                   ssid: "SurveyNet",
                   hidden_ssid: false,
                   frame_type: "beacon",
                   rssi_dbm: -47,
                   noise_floor_dbm: -95,
                   snr_db: 48,
                   frequency_mhz: 2412,
                   channel: 1,
                   channel_width_mhz: 20,
                   captured_at_unix_nanos: rf_unix_nanos,
                   captured_at_monotonic_nanos: 12_345_000_000,
                   parser_confidence: 0.98
                 }
               ]
             })
             |> Ash.run_action!(domain: ServiceRadar.Spatial)

    assert true =
             SurveyPoseSample
             |> Ash.ActionInput.for_action(:bulk_insert, %{
               session_id: session_id,
               samples: [
                 %{
                   scanner_device_id: "iphone-15-pro",
                   captured_at_unix_nanos: pose_unix_nanos,
                   captured_at_monotonic_nanos: 12_420_000_000,
                   x: 1.25,
                   y: 0.5,
                   z: -2.0,
                   qx: 0.0,
                   qy: 0.0,
                   qz: 0.0,
                   qw: 1.0,
                   latitude: 45.0,
                   longitude: -122.0,
                   altitude: 18.0,
                   accuracy_m: 0.03,
                   tracking_quality: "normal"
                 }
               ]
             })
             |> Ash.run_action!(domain: ServiceRadar.Spatial)

    assert true =
             SurveySpectrumObservation
             |> Ash.ActionInput.for_action(:bulk_insert, %{
               session_id: session_id,
               observations: [
                 %{
                   sidekick_id: "sidekick-rpi-1",
                   sdr_id: "hackrf-1",
                   device_kind: "hackrf",
                   serial_number: "0000000000000000f77c60dc299165c3",
                   sweep_id: 7,
                   started_at_unix_nanos: rf_unix_nanos,
                   captured_at_unix_nanos: rf_unix_nanos + 5_000_000,
                   start_frequency_hz: 2_400_000_000,
                   stop_frequency_hz: 2_484_000_000,
                   bin_width_hz: 1_000_000.0,
                   sample_count: 4,
                   power_bins_dbm: [-82.0, -75.5, -62.25, -79.0]
                 }
               ]
             })
             |> Ash.run_action!(domain: ServiceRadar.Spatial)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT COUNT(*) FROM platform.survey_rf_observations WHERE session_id = $1",
               [session_id]
             )

    assert %{rows: [[rf_features]]} =
             Repo.query!(
               """
               SELECT rf_features::text
               FROM platform.survey_rf_observations
               WHERE session_id = $1
               """,
               [session_id]
             )

    assert rf_features =~ "["

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT COUNT(*) FROM platform.survey_pose_samples WHERE session_id = $1",
               [session_id]
             )

    assert %{rows: [["POINT Z (1.25 0.5 -2)", -122.0, 45.0]]} =
             Repo.query!(
               """
               SELECT ST_AsText(position), ST_X(location::geometry), ST_Y(location::geometry)
               FROM platform.survey_pose_samples
               WHERE session_id = $1
               """,
               [session_id]
             )

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT COUNT(*) FROM platform.survey_spectrum_observations WHERE session_id = $1",
               [session_id]
             )

    assert %{rows: [[power_features]]} =
             Repo.query!(
               """
               SELECT power_features::text
               FROM platform.survey_spectrum_observations
               WHERE session_id = $1
               """,
               [session_id]
             )

    assert power_features =~ "["

    payload = <<1, 2, 3, 4, 5>>

    assert {1, _} =
             Repo.insert_all(
               "survey_arrow_ipc_frames",
               [
                 %{
                   session_id: session_id,
                   stream_type: "rf_observations",
                   user_id: "user-1",
                   frame_index: 1,
                   byte_size: byte_size(payload),
                   row_count: 1,
                   decode_status: "ok",
                   payload_sha256: :crypto.hash(:sha256, payload),
                   payload: payload,
                   received_at: DateTime.utc_now(),
                   inserted_at: DateTime.utc_now()
                 }
               ],
               prefix: "platform"
             )

    assert %{rows: [[byte_size(payload), "ok"]]} =
             Repo.query!(
               """
               SELECT byte_size, decode_status
               FROM platform.survey_arrow_ipc_frames
               WHERE session_id = $1 AND stream_type = 'rf_observations'
               """,
               [session_id]
             )

    assert %{
             rows: [
               [
                 "02:11:22:33:44:55",
                 "iphone-15-pro",
                 offset_nanos,
                 x,
                 z,
                 tracking_quality,
                 position_wkt,
                 longitude,
                 rf_feature_vector
               ]
             ]
           } =
             Repo.query!(
               """
               SELECT
                 bssid,
                 scanner_device_id,
                 pose_offset_nanos,
                 x,
                 z,
                 tracking_quality,
                 ST_AsText(position),
                 ST_X(location::geometry),
                 rf_features::text
               FROM platform.survey_rf_pose_matches
               WHERE session_id = $1
               """,
               [session_id]
             )

    assert offset_nanos == 75_000_000
    assert x == 1.25
    assert z == -2.0
    assert tracking_quality == "normal"
    assert position_wkt == "POINT Z (1.25 0.5 -2)"
    assert longitude == -122.0
    assert rf_feature_vector =~ "["
  end
end
