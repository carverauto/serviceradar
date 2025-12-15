defmodule ServiceRadarWebNG.TestSupport.SRQLStub do
  @moduledoc false

  @behaviour ServiceRadarWebNG.SRQLBehaviour

  @impl true
  def query_request(%{"query" => query}) when is_binary(query) do
    {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
  end

  def query_request(_payload) do
    {:error, :invalid_request}
  end
end
