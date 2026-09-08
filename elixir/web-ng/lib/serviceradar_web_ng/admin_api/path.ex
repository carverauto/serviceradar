defmodule ServiceRadarWebNG.AdminApi.Path do
  @moduledoc false

  def admin_path(segments) when is_list(segments) do
    encoded_segments =
      Enum.map(segments, fn segment ->
        segment
        |> to_string()
        |> URI.encode(&URI.char_unreserved?/1)
      end)

    "/api/admin/" <> Enum.join(encoded_segments, "/")
  end
end
