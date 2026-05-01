defmodule ServiceRadarWebNG.Dashboards.FrameRunnerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Dashboards.FrameRunner

  defmodule FakeSRQL do
    @moduledoc false
    def query("in:devices", opts) do
      limit = Map.fetch!(opts, :limit)
      {:ok, %{"results" => Enum.map(1..limit, &%{"id" => &1}), "pagination" => %{"limit" => limit}}}
    end

    def query("bad", _opts), do: {:error, :bad_query}
  end

  defmodule FakeArrowSRQL do
    @moduledoc false

    def query(_query, _opts), do: {:error, :json_should_not_run}

    def query_arrow("in:devices", opts) do
      limit = Map.fetch!(opts, :limit)

      {:ok,
       %{
         payload: "arrow-ipc:#{limit}",
         schema: %{"columns" => ["id"]},
         pagination: %{"limit" => limit}
       }}
    end
  end

  test "falls back to bounded JSON rows when Arrow IPC is not available" do
    frames = [
      %{
        "id" => "devices",
        "query" => "in:devices",
        "encoding" => "arrow_ipc",
        "limit" => 3
      }
    ]

    assert [
             %{
               "id" => "devices",
               "status" => "ok",
               "requested_encoding" => "arrow_ipc",
               "encoding" => "json_rows",
               "limit" => 3,
               "results" => [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL)
  end

  test "returns Arrow IPC frame payloads when the SRQL module supports them" do
    frames = [
      %{
        "id" => "devices",
        "query" => "in:devices",
        "encoding" => "arrow_ipc",
        "limit" => 3
      }
    ]

    assert [
             %{
               "id" => "devices",
               "status" => "ok",
               "requested_encoding" => "arrow_ipc",
               "encoding" => "arrow_ipc",
               "payload_encoding" => "base64",
               "payload" => payload,
               "byte_length" => 11,
               "results" => [],
               "schema" => %{"columns" => ["id"]},
               "pagination" => %{"limit" => 3}
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeArrowSRQL)

    assert Base.decode64!(payload) == "arrow-ipc:3"
  end

  test "returns per-frame errors without failing all frames" do
    frames = [
      %{"id" => "bad", "query" => "bad", "encoding" => "json_rows"},
      %{"id" => "ok", "query" => "in:devices", "encoding" => "json_rows", "limit" => 1}
    ]

    assert [
             %{"id" => "bad", "status" => "error", "error" => ":bad_query", "results" => []},
             %{"id" => "ok", "status" => "ok", "results" => [%{"id" => 1}]}
           ] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL)
  end

  test "caps frame count and row limit" do
    frames =
      for index <- 1..20 do
        %{"id" => "f#{index}", "query" => "in:devices", "encoding" => "json_rows", "limit" => 10_000}
      end

    results = FrameRunner.run(frames, :scope, srql_module: FakeSRQL)

    assert length(results) == 12
    assert Enum.all?(results, &(length(&1["results"]) == 2_000))
  end
end
