defmodule ServiceRadarWebNGWeb.CameraMultiviewTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNGWeb.CameraMultiview

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
        ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
