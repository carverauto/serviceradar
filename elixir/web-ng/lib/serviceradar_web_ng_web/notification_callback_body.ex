defmodule ServiceRadarWebNGWeb.NotificationCallbackBody do
  @moduledoc """
  The unsigned request envelope shared by notification parsing and raw-body retention.

  Callbacks accept at most 1 MiB before provider authentication. Match decoded
  path segments, as Phoenix does, so encoded routes cannot use the upload limit.
  """

  @limit 1_048_576

  def limit, do: @limit

  def callback?(%{path_info: path_info}) do
    path_info
    |> Enum.take(3)
    |> Enum.map(&URI.decode/1)
    |> Kernel.==(["api", "notifications", "callbacks"])
  end
end
