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

  test "runs declared SRQL data frames with bounded JSON rows" do
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
