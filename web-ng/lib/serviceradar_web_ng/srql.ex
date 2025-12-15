defmodule ServiceRadarWebNG.SRQL do
  @moduledoc false

  alias ServiceRadarWebNG.SRQL.Engine

  def query(query, opts \\ %{}) when is_binary(query) do
    Engine.query(%{
      "query" => query,
      "limit" => Map.get(opts, :limit),
      "cursor" => Map.get(opts, :cursor),
      "direction" => Map.get(opts, :direction),
      "mode" => Map.get(opts, :mode)
    })
  end

  def query_request(%{} = request) do
    Engine.query(request)
  end
end
