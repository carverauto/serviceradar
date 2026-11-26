defmodule ServiceRadarWebNG.CameraObservationsSRQLDbTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Camera.VantageObservation
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.SRQL

  @moduletag :web_ng_shared_fixture_db

  @valid_jfif <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
                0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xDA, 0x00, 0x08,
                0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFF, 0xD9>>

  setup do
    system = system_actor()
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    {:ok, %{system: system, user: user}}
  end

  test "in:camera_observations enforces dual RBAC, camera Source scope, liveness, FTS, and excludes crop_jpeg", %{
    system: system,
    user: user
  } do
    uniq = System.unique_integer([:positive])

    cam_west = create_source!(system, "Gate West 01", "sr:cam-west-#{uniq}")
    cam_east = create_source!(system, "Gate East 02", "sr:cam-east-#{uniq}")
    prof_west = create_profile!(system, cam_west.id)
    prof_east = create_profile!(system, cam_east.id)

    playable_entry = create_catalog_entry!(system, cam_west.id, prof_west.id, :present, nil)
    quarantined_entry = create_catalog_entry!(system, cam_west.id, prof_west.id, :quarantined, "operator_quarantine")
    other_entry = create_catalog_entry!(system, cam_east.id, prof_east.id, :present, nil)

    now_us = System.system_time(:microsecond)

    obs_west =
      create_observation!(system, %{
        observation_key: "obs-west-#{uniq}",
        camera_source_id: cam_west.id,
        stream_profile_id: prof_west.id,
        catalog_entry_id: playable_entry.id,
        source_mode: :recorded_block,
        timeline_ts_us: now_us - 10_000_000,
        category: "license_plate",
        label: "SR-0100",
        confidence: 0.94,
        crop_jpeg: @valid_jfif,
        attributes: %{"plate_text" => "SR-0100", "region" => "US-CO"},
        search_text: "SR-0100 US-CO vehicle license_plate"
      })

    _obs_quarantined =
      create_observation!(system, %{
        observation_key: "obs-quar-#{uniq}",
        camera_source_id: cam_west.id,
        stream_profile_id: prof_west.id,
        catalog_entry_id: quarantined_entry.id,
        source_mode: :recorded_block,
        timeline_ts_us: now_us - 8_000_000,
        category: "license_plate",
        label: "SR-0100",
        confidence: 0.91,
        crop_jpeg: nil,
        attributes: %{"plate_text" => "SR-0100"},
        search_text: "SR-0100 quarantined"
      })

    obs_live =
      create_observation!(system, %{
        observation_key: "obs-live-#{uniq}",
        camera_source_id: cam_west.id,
        stream_profile_id: prof_west.id,
        catalog_entry_id: nil,
        source_mode: :live_keyframe_tap,
        timeline_ts_us: now_us - 2_000_000,
        category: "license_plate",
        label: "TEST-742",
        confidence: 0.89,
        crop_jpeg: nil,
        attributes: %{"plate_text" => "TEST-742"},
        search_text: "TEST-742 live"
      })

    _obs_east =
      create_observation!(system, %{
        observation_key: "obs-east-#{uniq}",
        camera_source_id: cam_east.id,
        stream_profile_id: prof_east.id,
        catalog_entry_id: other_entry.id,
        source_mode: :recorded_block,
        timeline_ts_us: now_us - 5_000_000,
        category: "license_plate",
        label: "SR-0100",
        confidence: 0.96,
        crop_jpeg: @valid_jfif,
        attributes: %{"plate_text" => "SR-0100"},
        search_text: "SR-0100 east"
      })

    # Missing either permission fails closed
    assert {:error, :forbidden} =
             SRQL.query("in:camera_observations limit:10", %{
               scope: %Scope{user: user, permissions: MapSet.new(["devices.view"])}
             })

    assert {:error, :forbidden} =
             SRQL.query("in:camera_observations limit:10", %{
               scope: %Scope{user: user, permissions: MapSet.new(["devices.cameras.recordings.view"])}
             })

    # Authorized scope scoped strictly to cam_west
    scoped =
      Map.put(
        %Scope{user: user, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])},
        :authorized_camera_source_ids,
        [cam_west.id]
      )

    assert {:ok, %{"results" => rows}} =
             SRQL.query("in:camera_observations category:license_plate limit:10", %{scope: scoped})

    assert Enum.map(rows, & &1["id"]) == [to_string(obs_live.id), to_string(obs_west.id)]

    west_row = Enum.find(rows, &(&1["id"] == to_string(obs_west.id)))
    assert west_row["camera_display_name"] == "Gate West 01"
    assert west_row["has_crop"] == true
    assert west_row["label"] == "SR-0100"
    refute Map.has_key?(west_row, "crop_jpeg")

    live_row = Enum.find(rows, &(&1["id"] == to_string(obs_live.id)))
    assert live_row["has_crop"] == false
    assert live_row["source_mode"] == "live_keyframe_tap"

    # FTS search:"SR-0100" matches only the playable authorized SR-0100 row
    assert {:ok, %{"results" => [fts_row]}} =
             SRQL.query(~s(in:camera_observations search:"SR-0100" has_crop:true), %{scope: scoped})

    assert fts_row["id"] == to_string(obs_west.id)

    # Malformed UUID returns clean invalid_request instead of 500
    assert {:error, :invalid_request} =
             SRQL.query("in:camera_observations camera_source_id:not-a-uuid", %{scope: scoped})
  end

  test "in:camera_observations sorts camera_display_name in SQL before limit/offset, handles not_like NULL 3VL, and enforces live_keyframe_tap liveness",
       %{system: system, user: user} do
    uniq = System.unique_integer([:positive])

    cam_alpha = create_source!(system, "Alpha Gate 01", "sr:cam-alpha-#{uniq}")
    cam_zulu = create_source!(system, "Zulu Gate 02", "sr:cam-zulu-#{uniq}")
    prof_alpha = create_profile!(system, cam_alpha.id)
    prof_zulu = create_profile!(system, cam_zulu.id)

    playable_alpha = create_catalog_entry!(system, cam_alpha.id, prof_alpha.id, :present, nil)
    playable_zulu = create_catalog_entry!(system, cam_zulu.id, prof_zulu.id, :present, nil)
    quarantined_alpha = create_catalog_entry!(system, cam_alpha.id, prof_alpha.id, :quarantined, "operator_quarantine")

    now_us = System.system_time(:microsecond)

    # Newest timestamp is on Zulu, older timestamp is on Alpha; sort:camera_display_name:asc must
    # return Alpha first even with limit:1 (not an unsorted SQL slice).
    obs_alpha =
      create_observation!(system, %{
        observation_key: "obs-alpha-sort-#{uniq}",
        camera_source_id: cam_alpha.id,
        stream_profile_id: prof_alpha.id,
        catalog_entry_id: playable_alpha.id,
        source_mode: :recorded_block,
        worker_id: nil,
        timeline_ts_us: now_us - 20_000_000,
        category: "license_plate",
        label: "SR-0100",
        confidence: 0.94,
        search_text: ""
      })

    obs_zulu =
      create_observation!(system, %{
        observation_key: "obs-zulu-sort-#{uniq}",
        camera_source_id: cam_zulu.id,
        stream_profile_id: prof_zulu.id,
        catalog_entry_id: playable_zulu.id,
        source_mode: :recorded_block,
        worker_id: "worker-zulu",
        timeline_ts_us: now_us - 1_000_000,
        category: "license_plate",
        label: "TEST-742",
        confidence: 0.91,
        search_text: "TEST-742 zulu"
      })

    # live_keyframe_tap linked to a quarantined catalog entry must be excluded
    _obs_live_quarantined =
      create_observation!(system, %{
        observation_key: "obs-live-quar-#{uniq}",
        camera_source_id: cam_alpha.id,
        stream_profile_id: prof_alpha.id,
        catalog_entry_id: quarantined_alpha.id,
        source_mode: :live_keyframe_tap,
        timeline_ts_us: now_us - 500_000,
        category: "license_plate",
        label: "TEST-742",
        confidence: 0.85,
        search_text: "quarantined live"
      })

    scoped =
      Map.put(
        %Scope{user: user, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])},
        :authorized_camera_source_ids,
        [cam_alpha.id, cam_zulu.id]
      )

    assert {:ok, %{"results" => [first_asc], "pagination" => %{"next_cursor" => next_cursor}}} =
             SRQL.query("in:camera_observations sort:camera_display_name:asc limit:1", %{scope: scoped})

    assert first_asc["id"] == to_string(obs_alpha.id)
    assert first_asc["camera_display_name"] == "Alpha Gate 01"
    assert is_binary(next_cursor)

    assert {:ok, %{"results" => [second_asc]}} =
             SRQL.query("in:camera_observations sort:camera_display_name:asc limit:1", %{
               scope: scoped,
               cursor: next_cursor,
               direction: "next"
             })

    assert second_asc["id"] == to_string(obs_zulu.id)
    assert second_asc["camera_display_name"] == "Zulu Gate 02"

    assert {:ok, %{"results" => [first_desc]}} =
             SRQL.query("in:camera_observations sort:camera_display_name:desc limit:1", %{scope: scoped})

    assert first_desc["id"] == to_string(obs_zulu.id)

    # not_like via SRQL (!label) and on nullable worker_id/search must preserve obs_alpha where worker_id is nil
    assert {:ok, %{"results" => not_like_label_rows}} =
             SRQL.query(~s(in:camera_observations !label:"%742%" limit:10), %{scope: scoped})

    assert Enum.map(not_like_label_rows, & &1["id"]) == [to_string(obs_alpha.id)]

    assert {:ok, %Postgrex.Result{rows: [[alpha_id]]}} =
             ServiceRadarWebNG.SRQL.CameraObservationsQuery.execute(
               %{
                 "entity" => "camera_observations",
                 "fields" => ["id"],
                 "filters" => [%{"field" => "worker_id", "op" => "not_like", "value" => "%zulu%"}],
                 "order" => [%{"field" => "id", "direction" => "desc"}],
                 "limit" => 10
               },
               scoped
             )

    assert alpha_id == obs_alpha.id
  end

  defp create_source!(actor, display_name, device_uid) do
    Source
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device_uid,
        vendor: "synthetic",
        vendor_camera_id: device_uid,
        display_name: display_name
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_profile!(actor, camera_source_id) do
    StreamProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        camera_source_id: camera_source_id,
        profile_name: "main",
        codec: "h264"
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_catalog_entry!(actor, camera_source_id, stream_profile_id, local_state, quarantine_reason) do
    block =
      RecordingBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          camera_source_id: camera_source_id,
          stream_profile_id: stream_profile_id,
          block_key: "blk-#{System.unique_integer([:positive])}",
          storage_id: "00000000-0000-4000-8000-000000000199",
          state: :closed
        },
        actor: actor
      )
      |> Ash.create!()

    now = DateTime.utc_now()
    now_us = DateTime.to_unix(now, :microsecond)

    RecordingCatalogEntry
    |> Ash.Changeset.for_create(
      :create,
      %{
        camera_source_id: camera_source_id,
        stream_profile_id: stream_profile_id,
        recording_block_id: block.id,
        local_state: local_state,
        local_state_at: now,
        quarantine_reason: quarantine_reason,
        timeline_start_us: now_us - 60_000_000,
        timeline_end_us: now_us,
        time_basis: :received
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_observation!(actor, overrides) do
    attrs =
      Map.merge(
        %{
          pack_id: "io.serviceradar.vantage-alpr",
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.0",
          worker_kind: "camera_vlm",
          worker_id: "worker-1",
          model_id: "qwen3.5-4b",
          model_version: "1.0",
          fragment_sequence: 1,
          frame_sequence: 1,
          media_pts_ns: 1_000_000_000,
          time_basis: :received,
          track_id: "track-1",
          confidence: 0.9,
          bbox: %{"x1" => 0.32, "y1" => 0.58, "x2" => 0.48, "y2" => 0.66},
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read"
        },
        overrides
      )

    VantageObservation
    |> Ash.Changeset.for_create(:upsert_observation, attrs, actor: actor)
    |> Ash.create!()
  end
end
