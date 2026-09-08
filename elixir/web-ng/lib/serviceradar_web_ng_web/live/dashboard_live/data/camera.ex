defmodule ServiceRadarWebNGWeb.DashboardLive.Data.Camera do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @sobelow_skip ["SQL.Query"]
      defp camera_summary(_scope) do
        if relation_exists?("platform.camera_sources") do
          sql = """
          SELECT id::text, display_name, device_uid, availability_status
          FROM platform.camera_sources
          ORDER BY COALESCE(display_name, device_uid, id::text)
          LIMIT 100
          """

          case ServiceRadarWebNG.Repo.query(sql, []) do
            {:ok, %{rows: rows}} ->
              sources =
                Enum.map(rows, fn [id, display_name, device_uid, availability_status] ->
                  %{
                    id: id,
                    display_name: display_name,
                    device_uid: device_uid,
                    availability_status: availability_status
                  }
                end)

              total = length(sources)

              online =
                Enum.count(sources, fn source ->
                  source.availability_status in ["available", "online", "active", "healthy"]
                end)

              %{
                total: total,
                online: online,
                offline: max(total - online, 0),
                recording: active_camera_relay_count(),
                tiles: sources |> Enum.take(4) |> Enum.map(&camera_tile/1)
              }

            _ ->
              empty_camera_summary()
          end
        else
          empty_camera_summary()
        end
      rescue
        _ -> empty_camera_summary()
      end

      @sobelow_skip ["SQL.Query"]
      defp active_camera_relay_count do
        if relation_exists?("platform.camera_relay_sessions") do
          sql = """
          SELECT COUNT(DISTINCT camera_source_id)::bigint
          FROM platform.camera_relay_sessions
          WHERE status = 'active'
            AND media_ingest_id IS NOT NULL
            AND media_ingest_id <> ''
            AND (lease_expires_at IS NULL OR lease_expires_at > now())
          """

          case ServiceRadarWebNG.Repo.query(sql, []) do
            {:ok, %{rows: [[count]]}} -> to_int(count)
            _ -> 0
          end
        else
          0
        end
      rescue
        _ -> 0
      end
    end
  end
end
