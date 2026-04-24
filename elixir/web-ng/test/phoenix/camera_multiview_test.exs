defmodule ServiceRadarWebNGWeb.CameraMultiviewTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNGWeb.CameraMultiview

  describe "refresh_tile_session/2" do
    setup do
      previous_fetcher = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetcher)

      on_exit(fn ->
        restore_env(:camera_relay_session_fetcher, previous_fetcher)
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
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
