defmodule ServiceRadarWebNG.TestSupport.McpSRQLTranslationProbe do
  @moduledoc false

  @behaviour ServiceRadarWebNG.SRQLBehaviour

  alias ServiceRadarWebNG.SRQL.Native

  @impl true
  def query_request(%{"query" => query} = request) when is_binary(query) do
    with {:ok, json} <- Native.translate(query, request["limit"], nil, nil, nil),
         {:ok, %{"pagination" => pagination}} <- Jason.decode(json) do
      {:ok, %{"results" => [], "pagination" => pagination, "error" => nil}}
    end
  end

  def query_request(_request), do: {:error, :invalid_request}
end
