defmodule ServiceRadarWebNGWeb.CameraMultiviewTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub
  alias ServiceRadarWebNGWeb.CameraMultiview

  @moduletag :db_free

  describe "format_error/1" do
    test "includes the assigned agent id for offline relay targets" do
      assert CameraMultiview.format_error({:agent_offline, "agent-sr-test-pve04"}) ==
               "Assigned agent agent-sr-test-pve04 is offline"
    end
  end

  describe "refresh_tile_session/2" do
    setup do
      previous_fetcher = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetcher)
      previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)
      previous_open_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)

      on_exit(fn ->
        restore_env(:camera_relay_session_fetcher, previous_fetcher)
        restore_env(:camera_relay_session_manager, previous_manager)
        restore_env(:camera_relay_session_manager_open_result, previous_open_result)
      end)

      :ok
    end

    test "refreshes relay session structs without Access lookups" do
      session_id = Ecto.UUID.generate()
      refreshed_session = %RelaySession{id: session_id, status: :active}

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn ^session_id, _opts -> {:ok, refreshed_session} end
      )

      tile = %{label: "Camera", session: %RelaySession{id: session_id, status: :requested}}

      assert %{session: ^refreshed_session} = CameraMultiview.refresh_tile_session(nil, tile)
    end

    test "retries stale opening sessions once using the existing tile candidate" do
      session_id = Ecto.UUID.generate()
      retried_session = %{id: Ecto.UUID.generate(), status: :opening}

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn ^session_id, _opts ->
          {:ok,
           %RelaySession{
             id: session_id,
             status: :opening,
             media_ingest_id: nil,
             updated_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)
           }}
        end
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager,
        CameraRelaySessionManagerStub
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        {:ok, retried_session}
      )

      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      tile = %{
        camera_source_id: camera_source_id,
        stream_profile_id: stream_profile_id,
        label: "Front Door",
        detail: "Low",
        session: %RelaySession{id: session_id, status: :opening},
        relay_retry_attempted: false
      }

      assert %{
               relay_retry_attempted: true,
               session: %{id: new_session_id}
             } = CameraMultiview.refresh_tile_session(nil, tile)

      assert is_binary(new_session_id)
      assert new_session_id != session_id
    end

    test "surfaces an error after a stale opening session has already retried" do
      session_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn ^session_id, _opts ->
          {:ok,
           %RelaySession{
             id: session_id,
             status: :opening,
             media_ingest_id: nil,
             updated_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)
           }}
        end
      )

      tile = %{
        label: "Front Door",
        session: %RelaySession{id: session_id, status: :opening},
        relay_retry_attempted: true
      }

      assert %{session: nil, error: "Relay opening timed out"} =
               CameraMultiview.refresh_tile_session(nil, tile)
    end
  end

  describe "open_preview_tiles/2" do
    setup do
      previous_loader = Application.get_env(:serviceradar_web_ng, :camera_relay_candidate_loader)
      previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)
      previous_open_result = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager,
        CameraRelaySessionManagerStub
      )

      on_exit(fn ->
        restore_env(:camera_relay_candidate_loader, previous_loader)
        restore_env(:camera_relay_session_manager, previous_manager)
        restore_env(:camera_relay_session_manager_open_result, previous_open_result)
      end)

      :ok
    end

    test "continues past offline agents until enough relay previews open" do
      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_candidate_loader,
        fn _scope, _limit ->
          [
            preview_candidate("offline-camera", "Offline front"),
            preview_candidate("online-camera", "Online front"),
            preview_candidate("side-camera", "Side yard")
          ]
        end
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        fn
          "offline-camera", _stream_profile_id, _opts ->
            {:error, {:agent_offline, "agent-sr-test-pve04"}}

          camera_source_id, _stream_profile_id, _opts ->
            {:ok, %{id: "session-#{camera_source_id}", status: :opening}}
        end
      )

      assert [
               %{
                 camera_source_id: "online-camera",
                 session: %{id: "session-online-camera"},
                 error: nil
               }
             ] = CameraMultiview.open_preview_tiles(nil, 1)
    end

    test "returns failures only when no relay previews can open" do
      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_candidate_loader,
        fn _scope, _limit ->
          [
            preview_candidate("offline-camera", "Offline front"),
            preview_candidate("offline-side", "Offline side")
          ]
        end
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        fn _camera_source_id, _stream_profile_id, _opts ->
          {:error, {:agent_offline, "agent-sr-test-pve04"}}
        end
      )

      assert [
               %{
                 camera_source_id: "offline-camera",
                 session: nil,
                 error: "Assigned agent agent-sr-test-pve04 is offline"
               },
               %{camera_source_id: "offline-side", session: nil, error: "Assigned agent agent-sr-test-pve04 is offline"}
             ] = CameraMultiview.open_preview_tiles(nil, 2)
    end

    test "passes selected quality and layout_count to arity-3 candidate loaders" do
      parent = self()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_candidate_loader,
        fn _scope, _limit, opts ->
          send(parent, {:loaded_with_opts, opts})
          [preview_candidate("hd-camera", "HD front")]
        end
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        fn camera_source_id, _stream_profile_id, _opts ->
          {:ok, %{id: "session-#{camera_source_id}", status: :opening}}
        end
      )

      assert [%{camera_source_id: "hd-camera"}] = CameraMultiview.open_preview_tiles(nil, 4, quality: "high")
      assert_received {:loaded_with_opts, opts}
      assert opts[:quality] == "high"
      assert opts[:layout_count] == 4
    end
  end

  describe "select_profile_for_quality/4" do
    test "selects matching stream profile for high, medium, low, auto, and explicit profile id" do
      profiles = [
        %{id: "p-low", profile_name: "Low", relay_eligible: true},
        %{id: "p-med", profile_name: "Medium", relay_eligible: true},
        %{id: "p-high", profile_name: "High", relay_eligible: true},
        %{id: "p-disabled", profile_name: "High", relay_eligible: false}
      ]

      assert %{id: "p-high"} = CameraMultiview.select_profile_for_quality(profiles, "high", 4)
      assert %{id: "p-med"} = CameraMultiview.select_profile_for_quality(profiles, "medium", 4)
      assert %{id: "p-low"} = CameraMultiview.select_profile_for_quality(profiles, "low", 4)
      # Auto adapts: medium for <= 4 tiles, low for 8+ dense walls
      assert %{id: "p-med"} = CameraMultiview.select_profile_for_quality(profiles, "auto", 4)
      assert %{id: "p-low"} = CameraMultiview.select_profile_for_quality(profiles, "auto", 8)
      # Explicit profile id wins when eligible
      assert %{id: "p-low"} = CameraMultiview.select_profile_for_quality(profiles, "high", 1, "p-low")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp preview_candidate(camera_source_id, label) do
    %{
      camera_source_id: camera_source_id,
      stream_profile_id: "profile-#{camera_source_id}",
      label: label,
      detail: "Primary stream",
      session: nil,
      error: nil
    }
  end
end
